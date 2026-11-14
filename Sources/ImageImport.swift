import AppKit
import UniformTypeIdentifiers

enum ImageImport {
    case file(URL)
    case pixels(Data)

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false)
    }
    static func from(_ pasteboard: NSPasteboard) -> [ImageImport] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.filter(accepts)
            if !images.isEmpty { return images.map(ImageImport.file) }
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return [.pixels(data)] }
        return []
    }
    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: [.png, .tiff]) != nil { return true }
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .contains(where: accepts) ?? false
    }
    static func write(_ items: [ImageImport], beside document: URL) throws -> [String] {
        let directory = document.deletingLastPathComponent()
            .appendingPathComponent(document.deletingPathExtension().lastPathComponent + ".assets", isDirectory: true)
        let prepared: [(Data, String, String)] = try items.map { item in
            switch item {
            case .file(let url):
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw ImageFailure.tooLarge }
                let data = try Data(contentsOf: url)
                _ = try ImageStore.decode(data)
                return (data, url.pathExtension.lowercased(), url.deletingPathExtension().lastPathComponent)
            case .pixels(let data):
                _ = try ImageStore.decode(data)
                if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return (data, "png", "图片") }
                guard let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]) else { throw ImageFailure.unreadable }
                return (png, "png", "图片")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        do {
            var links: [String] = []
            for (data, ext, title) in prepared {
                let url = directory.appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
                try data.write(to: url, options: .withoutOverwriting)
                written.append(url)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let path = [directory.lastPathComponent, url.lastPathComponent]
                    .map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
                let alt = title.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                links.append("![" + alt + "](<" + path + ">)")
            }
            return links
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

private final class ImageSaveCompletion {
    let perform: (Bool) -> Void
    init(_ perform: @escaping (Bool) -> Void) { self.perform = perform }
}

extension MarkdownDocument {
    func saveForImageInsertion(_ completion: @escaping (Bool) -> Void) {
        guard fileURL == nil else { completion(true); return }
        let box = Unmanaged.passRetained(ImageSaveCompletion(completion))
        save(withDelegate: self, didSave: #selector(imageDocumentSaved(_:didSave:contextInfo:)), contextInfo: box.toOpaque())
    }
    @objc private func imageDocumentSaved(_ document: NSDocument, didSave: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        Unmanaged<ImageSaveCompletion>.fromOpaque(contextInfo).takeRetainedValue().perform(didSave)
    }
}
