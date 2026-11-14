import AppKit

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var source = ""
    var codec = FileCodec()

    override var fileURL: URL? {
        didSet {
            if oldValue != fileURL {
                for case let controller as EditorWindowController in windowControllers {
                    controller.refreshSourcePresentation()
                }
            }
        }
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let controller = EditorWindowController(document: self)
        addWindowController(controller)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        (source, codec) = try FileCodec.decode(data)
        for case let controller as EditorWindowController in windowControllers {
            controller.loadSource()
        }
    }

    override func data(ofType typeName: String) throws -> Data { try codec.encode(source) }

    func edited(_ text: String, sender: EditorWindowController) {
        guard source != text else { return }
        source = text
        updateChangeCount(.changeDone)
        for case let controller as EditorWindowController in windowControllers where controller !== sender {
            controller.loadSource()
        }
    }
}

final class MarkdownDocumentController: NSDocumentController {
    static let typeName = "net.qingmo.markdown"
    override var defaultType: String? { Self.typeName }
    override func typeForContents(of url: URL) throws -> String { Self.typeName }
    override func documentClass(forType typeName: String) -> AnyClass? { MarkdownDocument.self }
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let document = MarkdownDocument()
        document.fileType = Self.typeName
        return document
    }
}
