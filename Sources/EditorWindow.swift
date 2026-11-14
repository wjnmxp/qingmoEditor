import AppKit
import UniformTypeIdentifiers

final class PaperView: NSView {
    var fill: NSColor = Palette.paper
    override func draw(_ dirtyRect: NSRect) { fill.setFill(); dirtyRect.fill() }
}

final class WritingTextView: NSTextView {
    weak var tableCoordinator: TableCoordinator?
    weak var imageCoordinator: ImageCoordinator?

    // Tables, images and body text share the same content column.
    var contentColumn: NSRect {
        let padding = textContainer?.lineFragmentPadding ?? 5
        let x = textContainerInset.width + padding
        return NSRect(x: x, y: 0, width: max(1, bounds.width - x * 2), height: 0)
    }
    override func mouseDown(with event: NSEvent) {
        tableCoordinator?.finishEditing()
        super.mouseDown(with: event)
    }

    override func paste(_ sender: Any?) {
        if let controller = delegate as? EditorWindowController,
           controller.insertImages(from: .general) { return }
        super.paste(sender)
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, .png, .tiff]
    }
    override func dragOperation(for info: NSDraggingInfo, type: NSPasteboard.PasteboardType) -> NSDragOperation {
        let operation = super.dragOperation(for: info, type: type)
        return ImageImport.canRead(info.draggingPasteboard) ? .copy : operation
    }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        if ImageImport.canRead(info.draggingPasteboard), let controller = delegate as? EditorWindowController {
            let point = convert(info.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            return controller.insertImages(from: info.draggingPasteboard)
        }
        return super.performDragOperation(info)
    }

    static func liveEditor() -> WritingTextView {
        let storage = NSTextStorage()
        let layout = LiveLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        return WritingTextView(frame: .zero, textContainer: container)
    }

    override func draw(_ dirtyRect: NSRect) {
        tableCoordinator?.positionViews()
        imageCoordinator?.positionViews()
        super.draw(dirtyRect)
        guard string.isEmpty, isEditable else { return }
        let x = textContainerInset.width + 5
        ("写一点什么。" as NSString).draw(at: NSPoint(x: x, y: 58),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .medium),
                                                      .foregroundColor: NSColor.tertiaryLabelColor])
        ("从一个想法开始。\n⌘N 新窗口   ·   ⌘O 打开文件" as NSString).draw(
            at: NSPoint(x: x, y: 110),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14),
                             .foregroundColor: NSColor.tertiaryLabelColor,
                             .paragraphStyle: MarkdownAppearance.paragraph(size: 14)])
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            DispatchQueue.main.async { [weak self] in self?.tableCoordinator?.refresh?() }
        }
        let margin = max(28, (newSize.width - 720) / 2)
        if abs(textContainerInset.width - margin) > 0.5 {
            textContainerInset = NSSize(width: margin, height: 42)
        }
    }

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText(), selectedRange().length == 0 else { super.insertNewline(sender); return }
        let text = string as NSString
        let selection = selectedRange()
        guard !MarkdownSnapshot(string).isCode(at: max(0, selection.location - 1)) else {
            super.insertNewline(sender)
            return
        }
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        guard let regex = try? NSRegularExpression(pattern: #"^(\s*)([-+*]|\d+[.)])(\s+)(\[[ xX]\]\s+)?"#),
              let match = regex.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length))
        else { super.insertNewline(sender); return }
        let nsBefore = before as NSString
        if match.range.length == nsBefore.length {
            insertText("", replacementRange: NSRange(location: line.location, length: before.utf16.count))
            return
        }
        let indent = nsBefore.substring(with: match.range(at: 1))
        var marker = nsBefore.substring(with: match.range(at: 2))
        if let number = Int(marker.dropLast()), let suffix = marker.last { marker = "\(number + 1)\(suffix)" }
        let task = match.range(at: 4).location == NSNotFound ? "" : "[ ] "
        let newline = string.contains("\r\n") ? "\r\n" : "\n"
        insertText(newline + indent + marker + " " + task, replacementRange: selection)
    }
}

final class EditorWindowController: NSWindowController, NSTextViewDelegate, NSTableViewDataSource,
                                    NSTableViewDelegate, NSToolbarDelegate, NSWindowDelegate {
    private weak var markdownDocument: MarkdownDocument?
    let editor = WritingTextView.liveEditor()
    private let editorScroll = NSScrollView()
    private let sidebar = PaperView()
    private let table = NSTableView()
    private let sidebarEmpty = NSTextField(wrappingLabelWithString: "用 # 写下标题\n这里就会出现大纲")
    private let stats = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private var sidebarWidth: NSLayoutConstraint!
    private var snapshot = MarkdownSnapshot("")
    private(set) var tablePresentation: TableCoordinator!
    private(set) var imagePresentation: ImageCoordinator!
    private var applying = false
    private var deferredStyle: DispatchWorkItem?
    private var size = MarkdownAppearance.defaultSize
    private var isSidebarVisible = true
    private var characterCount = 0

    init(document: MarkdownDocument) {
        markdownDocument = document
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 600, height: 420)
        window.title = "未命名"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.paper
        super.init(window: window)
        window.delegate = self
        setupContent()
        setupToolbar()
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat((NSDocumentController.shared.documents.count % 5) * 24),
                                      y: window.frame.minY - CGFloat((NSDocumentController.shared.documents.count % 5) * 24)))
        loadSource()
        window.makeFirstResponder(editor)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }
    deinit { deferredStyle?.cancel() }

    private func setupContent() {
        guard let window else { return }
        let root = PaperView()
        window.contentView = root
        sidebar.fill = Palette.sidebar
        [sidebar, editorScroll, stats, state].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview($0)
        }
        configureEditor()
        editor.setAccessibilityLabel("Markdown 即时编辑器")
        stats.font = .systemFont(ofSize: 11)
        stats.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 11)
        state.textColor = .secondaryLabelColor
        state.alignment = .right
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 188)

        let label = NSTextField(labelWithString: "文档大纲")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(label)
        let outlineScroll = NSScrollView()
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.drawsBackground = false
        outlineScroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("heading"))
        column.width = 165
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 31
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(selectHeading)
        table.setAccessibilityLabel("文档大纲")
        outlineScroll.documentView = table
        sidebar.addSubview(outlineScroll)
        sidebarEmpty.font = .systemFont(ofSize: 12)
        sidebarEmpty.textColor = .tertiaryLabelColor
        sidebarEmpty.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarEmpty)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebarWidth,
            editorScroll.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            editorScroll.topAnchor.constraint(equalTo: root.topAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: stats.topAnchor, constant: -10),
            stats.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            stats.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            state.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: stats.trailingAnchor, constant: 12),
            state.centerYAnchor.constraint(equalTo: stats.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            label.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            outlineScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            outlineScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            outlineScroll.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            outlineScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            sidebarEmpty.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            sidebarEmpty.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
            sidebarEmpty.widthAnchor.constraint(equalToConstant: 150)
        ])
    }

    private func configureEditor() {
        let view = editor
        let scroll = editorScroll
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = true
        view.backgroundColor = Palette.paper
        view.textColor = Palette.text
        view.insertionPointColor = Palette.accent
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 40, height: 42)
        view.font = MarkdownAppearance.bodyFont(size: size)
        view.defaultParagraphStyle = MarkdownAppearance.paragraph(size: size)
        view.delegate = self
        scroll.documentView = view
        tablePresentation = TableCoordinator(editor: view)
        view.tableCoordinator = tablePresentation
        tablePresentation.refresh = { [weak self] in self?.refreshPresentation() }
        imagePresentation = ImageCoordinator(editor: view)
        view.imageCoordinator = imagePresentation
        imagePresentation.refresh = { [weak self] in self?.refreshPresentation() }
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "QingmoToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("outline"), .init("new"), .init("open"), .init("image"), .flexibleSpace, .init("save")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let config: (String, String, Selector, AnyObject?)
        switch id.rawValue {
        case "outline": config = ("显示 / 隐藏大纲", "sidebar.left", #selector(toggleOutline), self)
        case "new": config = ("新窗口（⌘N）", "square.and.pencil", #selector(NSDocumentController.newDocument(_:)), NSDocumentController.shared)
        case "open": config = ("在新窗口打开（⌘O）", "folder", #selector(NSDocumentController.openDocument(_:)), NSDocumentController.shared)
        case "image": config = ("插入图片（⇧⌘I）", "photo", #selector(insertImage), self)
        case "save": config = ("保存（⌘S）", "square.and.arrow.down", #selector(save), self)
        default: return nil
        }
        item.label = config.0
        item.toolTip = config.0
        item.image = NSImage(systemSymbolName: config.1, accessibilityDescription: config.0)
        item.target = config.3
        item.action = config.2
        item.isBordered = true
        return item
    }

    func loadSource() {
        guard let doc = markdownDocument else { return }
        applying = true
        tablePresentation?.finishEditing(refresh: false)
        editor.string = doc.source
        applying = false
        restyle()
    }

    func textDidChange(_ notification: Notification) {
        guard !applying, notification.object as? NSTextView === editor else { return }
        // The input method owns marked text until it commits.
        if !editor.hasMarkedText() { markdownDocument?.edited(editor.string, sender: self) }
        deferredStyle?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.restyle() }
        deferredStyle = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: task)
        editor.needsDisplay = true
        updateStatus()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        // Old source offsets must not be reused after a character edit.
        if !applying {
            let manager = editor.layoutManager as? LiveLayoutManager
            manager?.setTableLineHeights([:])
            manager?.present(hidden: [], replacements: [:])
        }
        return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applying, !editor.hasMarkedText(), snapshot.source == editor.string else { return }
        refreshPresentation()
        tablePresentation.enterSelectedCell()
    }

    func refreshSourcePresentation() {
        deferredStyle?.cancel()
        restyle()
    }

    private func restyle() {
        guard !editor.hasMarkedText() else { return }
        snapshot = MarkdownSnapshot(editor.string, baseURL: markdownDocument?.fileURL?.deletingLastPathComponent())
        characterCount = editor.string.filter { !$0.isWhitespace }.count
        refreshPresentation()
        table.reloadData()
        sidebarEmpty.isHidden = !snapshot.headings.isEmpty
        updateStatus()
    }

    private func refreshPresentation() {
        guard !applying, let storage = editor.textStorage, !editor.hasMarkedText(), tablePresentation != nil else { return }
        // Undo may change source just before focus, resize or cell-exit requests a presentation.
        // Never apply ranges or table geometry from an older source revision.
        guard snapshot.source == editor.string else { restyle(); return }
        applying = true
        defer { applying = false }
        let selections = editor.selectedRanges.map(\.rangeValue)
        let presentation = snapshot.presentation(selections: selections)
        MarkdownAppearance.apply(snapshot, to: storage, size: size, selections: selections)
        tablePresentation.prepare(snapshot: snapshot, size: size)
        imagePresentation.prepare(snapshot: snapshot, selections: selections)
        let (tableCharacters, rowHeights) = tablePresentation.configureStorage(storage)
        let imageCharacters = imagePresentation.configureStorage(storage)
        if let manager = editor.layoutManager as? LiveLayoutManager {
            manager.setTableLineHeights(rowHeights)
            manager.present(hidden: presentation.hidden.union(tableCharacters).union(imageCharacters), replacements: presentation.replacements)
        }
        editor.typingAttributes = MarkdownAppearance.base(size: size)
        tablePresentation.positionViews()
        imagePresentation.positionViews()
        editor.needsDisplay = true
    }

    private func updateStatus() {
        stats.stringValue = "即时预览  ·  \(characterCount) 字符  ·  \(snapshot.headings.count) 个标题"
        if let doc = markdownDocument {
            if doc.fileURL == nil { state.stringValue = "未命名文档 · ⌘S 保存" }
            else { state.stringValue = "\(doc.codec.label) · \(doc.isDocumentEdited ? "待保存" : "已保存")" }
        }
    }

    func windowDidUpdate(_ notification: Notification) { updateStatus() }
    func windowWillClose(_ notification: Notification) { imagePresentation?.cancel() }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { markdownDocument?.undoManager }

    @objc func save(_ sender: Any?) { markdownDocument?.save(sender) }

    @objc func toggleOutline(_ sender: Any?) {
        isSidebarVisible.toggle()
        sidebarWidth.constant = isSidebarVisible ? 188 : 0
        sidebar.isHidden = !isSidebarVisible
    }

    @objc func increaseFont(_ sender: Any?) { size = min(size + 1, 32); restyle() }
    @objc func decreaseFont(_ sender: Any?) { size = max(size - 1, 12); restyle() }
    @objc func resetFont(_ sender: Any?) { size = MarkdownAppearance.defaultSize; restyle() }

    @objc func bold(_ sender: Any?) { wrapSelection("**", "**") }
    @objc func italic(_ sender: Any?) { wrapSelection("*", "*") }
    @objc func inlineCode(_ sender: Any?) { wrapSelection("\u{0060}", "\u{0060}") }
    @objc func insertLink(_ sender: Any?) { wrapSelection("[", "](https://)") }

    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "插入图片"
        panel.prompt = "插入"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importImages(panel.urls.map(ImageImport.file)) }
        }
    }

    @discardableResult
    func insertImages(from pasteboard: NSPasteboard) -> Bool {
        let items = ImageImport.from(pasteboard)
        guard !items.isEmpty else { return false }
        importImages(items)
        return true
    }

    func importImages(_ items: [ImageImport]) {
        guard !items.isEmpty, let document = markdownDocument else { return }
        if let address = tablePresentation.active {
            let end = NSMaxRange(tablePresentation.layouts[address.table].table.range)
            tablePresentation.finishEditing()
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
        document.saveForImageInsertion { [weak self, weak document] saved in
            guard saved, let self, let url = document?.fileURL else { return }
            do {
                let links = try ImageImport.write(items, beside: url)
                let newline = self.editor.string.contains("\r\n") ? "\r\n" : "\n"
                let selection = self.editor.selectedRange()
                let before = (self.editor.string as NSString).substring(to: selection.location)
                let prefix = before.isEmpty || before.hasSuffix(newline + newline) ? ""
                    : before.hasSuffix(newline) ? newline : newline + newline
                self.editor.insertText(prefix + links.joined(separator: newline + newline) + newline + newline,
                                       replacementRange: selection)
                self.refreshSourcePresentation()
                self.window?.makeFirstResponder(self.editor)
            } catch { self.window?.presentError(error) }
        }
    }

    private func wrapSelection(_ left: String, _ right: String) {
        let target = tablePresentation.cellEditor ?? editor
        let selection = target.selectedRange()
        let chosen = (target.string as NSString).substring(with: selection)
        target.insertText(left + chosen + right, replacementRange: selection)
        target.setSelectedRange(NSRange(location: selection.location + left.utf16.count, length: selection.length))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { snapshot.headings.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let heading = snapshot.headings[row]
        let label = NSTextField(labelWithString: String(repeating: "  ", count: max(0, heading.level - 1)) + heading.title)
        label.font = .systemFont(ofSize: 12, weight: heading.level == 1 ? .semibold : .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = heading.title
        return label
    }

    @objc private func selectHeading(_ sender: Any?) {
        let row = table.selectedRow
        guard snapshot.headings.indices.contains(row) else { return }
        let heading = snapshot.headings[row]
        editor.setSelectedRange(NSRange(location: heading.range.location, length: 0))
        if let manager = editor.layoutManager {
            let glyph = manager.glyphIndexForCharacter(at: heading.range.location)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = max(0, rect.minY + editor.textContainerOrigin.y - 24)
            editorScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            editorScroll.reflectScrolledClipView(editorScroll.contentView)
        }
        window?.makeFirstResponder(editor)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto", "file"].contains(scheme) else { return true }
        if url.isFileURL && ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
