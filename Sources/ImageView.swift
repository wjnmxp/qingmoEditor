import AppKit
import ImageIO

enum ImageFailure: LocalizedError {
    case unreadable, tooLarge, response
    var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取图片，请检查路径或图片格式"
        case .tooLarge: return "图片超过 32 MB，请使用较小的图片"
        case .response: return "网络图片加载失败"
        }
    }
}

/// A bounded download. No cookies, credentials or document text are sent.
private final class ImageDownload: NSObject, URLSessionDataDelegate {
    static let byteLimit = 32 * 1024 * 1024
    private var session: URLSession?
    private var bytes = Data()
    private var completed = false
    private let completion: (Result<Data, Error>) -> Void
    init(url: URL, completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        session.dataTask(with: url).resume()
    }
    func cancel() { session?.invalidateAndCancel() }
    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        session?.finishTasksAndInvalidate()
        completion(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel); finish(.failure(ImageFailure.response)); return
        }
        guard response.expectedContentLength <= Self.byteLimit else {
            completionHandler(.cancel); finish(.failure(ImageFailure.tooLarge)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !completed else { return }
        guard bytes.count <= Self.byteLimit - data.count else {
            dataTask.cancel(); finish(.failure(ImageFailure.tooLarge)); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(bytes)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") ? request : nil)
    }
}

final class ImageStore {
    struct Info {
        var size: NSSize?
        var error: String?
        var token: UUID?
    }
    private var info: [URL: Info] = [:]
    private var downloads: [URL: ImageDownload] = [:]
    private let cache = NSCache<NSURL, NSImage>()
    var changed: (() -> Void)?
    init() { cache.totalCostLimit = 96 * 1024 * 1024 }
    deinit { for download in downloads.values { download.cancel() } }
    func image(for url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }
    func state(for url: URL) -> Info { info[url] ?? Info() }

    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= ImageDownload.byteLimit else { throw ImageFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImageFailure.unreadable }
        return image
    }

    func retain(_ urls: Set<URL>) {
        for url in Array(info.keys) where !urls.contains(url) {
            downloads.removeValue(forKey: url)?.cancel()
            cache.removeObject(forKey: url as NSURL)
            info.removeValue(forKey: url)
        }
    }
    func cancel() {
        for task in downloads.values { task.cancel() }
        downloads.removeAll()
        info.removeAll()
        cache.removeAllObjects()
    }
    func reload(_ url: URL) {
        downloads.removeValue(forKey: url)?.cancel()
        cache.removeObject(forKey: url as NSURL)
        info.removeValue(forKey: url)
        request(url)
    }
    func request(_ url: URL) {
        guard image(for: url) == nil, state(for: url).token == nil, state(for: url).error == nil else { return }
        let token = UUID()
        info[url, default: Info()].token = token
        let complete: (Result<Data, Error>) -> Void = { [weak self] result in
            DispatchQueue.global(qos: .utility).async {
                let decoded = result.flatMap { data in Result { try Self.decode(data) } }
                DispatchQueue.main.async {
                    guard let self, self.info[url]?.token == token else { return }
                    self.downloads.removeValue(forKey: url)
                    self.info[url]?.token = nil
                    switch decoded {
                    case .success(let cg):
                        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        self.cache.setObject(image, forKey: url as NSURL, cost: cg.bytesPerRow * cg.height)
                        self.info[url]?.size = image.size
                    case .failure(let error):
                        self.info[url]?.error = (error as? ImageFailure)?.errorDescription
                            ?? (url.isFileURL ? "图片文件不存在或无法读取" : "网络图片暂时无法加载")
                    }
                    self.changed?()
                }
            }
        }
        if url.isFileURL {
            DispatchQueue.global(qos: .utility).async {
                complete(Result {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= ImageDownload.byteLimit else { throw ImageFailure.tooLarge }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                })
            }
        } else {
            downloads[url] = ImageDownload(url: url, completion: complete)
        }
    }
}

final class ImagePreviewView: NSView {
    weak var coordinator: ImageCoordinator?
    var reference: MarkdownImage!
    var image: NSImage?
    var message = "正在加载图片…"
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let image {
            let width = min(bounds.width, image.size.width)
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            Palette.tableStripe.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            let caption = reference.alt.isEmpty ? message : reference.alt + " · " + message
            (caption as NSString).draw(in: bounds.insetBy(dx: 14, dy: 18),
                withAttributes: [.font: MarkdownAppearance.bodyFont(size: 13), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    override func mouseDown(with event: NSEvent) { coordinator?.edit(reference) }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "编辑图片路径", action: #selector(editSource), keyEquivalent: "")
        edit.target = self; menu.addItem(edit)
        if reference.url != nil {
            let reload = NSMenuItem(title: "重新加载图片", action: #selector(reloadImage), keyEquivalent: "")
            reload.target = self; menu.addItem(reload)
        }
        return menu
    }
    @objc private func editSource() { coordinator?.edit(reference) }
    @objc private func reloadImage() { if let url = reference.url { coordinator?.store.reload(url) } }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { reference.alt.isEmpty ? "Markdown 图片" : reference.alt }
    override func accessibilityHelp() -> String? { image == nil ? message : "点击编辑图片的 Markdown 路径" }
    override func accessibilityPerformPress() -> Bool { coordinator?.edit(reference); return true }
}

/// Reserves paragraph space for image previews, keeping selection and undo in
/// Markdown coordinates. Inline prose remains above the image on its own line.
final class ImageCoordinator {
    struct Group {
        var range: NSRange
        var images: [MarkdownImage]
        var active: Bool
        var compact: Bool
        var heights: [CGFloat]
        var reservedHeight: CGFloat { heights.reduce(0, +) + CGFloat(heights.count) * 12 + 8 }
    }
    weak var editor: WritingTextView?
    let store = ImageStore()
    var refresh: (() -> Void)?
    private(set) var groups: [Group] = []
    private(set) var views: [ImagePreviewView] = []
    private var source = ""
    private var positioning = false
    init(editor: WritingTextView) {
        self.editor = editor
        store.changed = { [weak self] in self?.refresh?() }
    }
    func cancel() { store.cancel() }
    func prepare(snapshot: MarkdownSnapshot, selections: [NSRange]) {
        guard let editor else { return }
        source = snapshot.source
        let text = source as NSString
        store.retain(Set(snapshot.images.compactMap(\.url)))
        var groups: [Group] = []
        for image in snapshot.images {
            let line = text.lineRange(for: image.range)
            if let last = groups.indices.last, NSIntersectionRange(groups[last].range, line).length > 0 {
                groups[last].range = NSUnionRange(groups[last].range, line)
                groups[last].images.append(image)
            } else { groups.append(Group(range: line, images: [image], active: false, compact: false, heights: [])) }
        }
        for i in groups.indices {
            groups[i].active = selections.contains {
                $0.length == 0 ? NSLocationInRange($0.location, groups[i].range) : NSIntersectionRange($0, groups[i].range).length > 0
            }
            var remainder = text.substring(with: groups[i].range)
            for image in groups[i].images.reversed() {
                remainder = (remainder as NSString).replacingCharacters(
                    in: NSRange(location: image.range.location - groups[i].range.location, length: image.range.length), with: "")
            }
            groups[i].compact = !groups[i].active && remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            groups[i].heights = groups[i].images.map { image in
                guard let url = image.url else { return 58 }
                let info = store.state(for: url)
                if let size = info.size, size.width > 0 {
                    return ceil(size.height * min(1, editor.contentColumn.width / size.width))
                }
                return info.error == nil ? 160 : 58
            }
        }
        self.groups = groups
        let references = groups.flatMap(\.images)
        while views.count > references.count { views.removeLast().removeFromSuperview() }
        while views.count < references.count {
            let view = ImagePreviewView()
            view.coordinator = self
            views.append(view)
            editor.addSubview(view)
        }
        for (view, reference) in zip(views, references) {
            view.reference = reference
            view.toolTip = reference.destination
            view.image = reference.url.flatMap { store.image(for: $0) }
            view.message = reference.url.map { store.state(for: $0).error ?? "正在加载图片…" }
                ?? "请检查路径；相对路径需要先保存文稿"
            view.needsDisplay = true
        }
    }
    func configureStorage(_ storage: NSTextStorage) -> IndexSet {
        var hidden = IndexSet()
        let text = source as NSString
        for group in groups {
            if !group.active {
                for image in group.images {
                    for i in image.range.location..<NSMaxRange(image.range) where ![10, 13].contains(text.character(at: i)) {
                        hidden.insert(i)
                    }
                }
            }
            let lastLine = text.lineRange(for: NSRange(location: max(group.range.location, NSMaxRange(group.range) - 1), length: 0))
            if group.compact {
                let compact = NSMutableParagraphStyle()
                compact.minimumLineHeight = 1
                compact.maximumLineHeight = 1
                storage.addAttributes([.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: compact], range: group.range)
            }
            let style = (storage.attribute(.paragraphStyle, at: lastLine.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.paragraphSpacing += group.reservedHeight
            storage.addAttribute(.paragraphStyle, value: style, range: lastLine)
        }
        return hidden
    }
    func positionViews() {
        guard !positioning, let editor, editor.string == source, let manager = editor.layoutManager,
              let container = editor.textContainer else { return }
        positioning = true
        defer { positioning = false }
        manager.ensureLayout(for: container)
        var index = 0
        for group in groups {
            let last = max(group.range.location, NSMaxRange(group.range) - 1)
            let glyph = manager.glyphIndexForCharacter(at: last)
            let line = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            var y = editor.textContainerOrigin.y + line.maxY + 8
            for (reference, height) in zip(group.images, group.heights) {
                let view = views[index]
                view.frame = NSRect(x: editor.contentColumn.minX, y: y, width: editor.contentColumn.width, height: height)
                if view.frame.intersects(editor.visibleRect.insetBy(dx: 0, dy: -200)), let url = reference.url {
                    // Visible views retain their bitmap. Off-screen previews relinquish
                    // it so the cache can actually enforce its memory budget.
                    let cached = store.image(for: url)
                    if view.image !== cached { view.image = cached; view.needsDisplay = true }
                    store.request(url)
                } else if view.image != nil {
                    view.image = nil
                    view.needsDisplay = true
                }
                y += height + 12
                index += 1
            }
        }
    }
    func edit(_ image: MarkdownImage) {
        guard let editor, editor.string == source else { return }
        editor.tableCoordinator?.finishEditing()
        editor.setSelectedRange(image.range)
        editor.window?.makeFirstResponder(editor)
        editor.scrollRangeToVisible(image.range)
    }
}
