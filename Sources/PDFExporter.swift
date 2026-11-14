import AppKit

/// Loads the same image formats as the editor, including images outside its viewport.
final class PDFExportJob {
    private let store = ImageStore()
    private var pending: ArraySlice<URL>
    private var loading: Set<URL> = []
    private var images: [URL: NSImage] = [:]
    private let snapshot: MarkdownSnapshot
    private let title: String
    private let destination: URL

    init(snapshot: MarkdownSnapshot, title: String, destination: URL) {
        self.snapshot = snapshot
        self.title = title
        self.destination = destination
        pending = Array(Set(snapshot.images.compactMap(\.url)))[...]
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        store.changed = { [weak self] in self?.advance(completion: completion) }
        advance(completion: completion)
    }

    private func advance(completion: @escaping (Result<Void, Error>) -> Void) {
        for url in Array(loading) where store.state(for: url).token == nil {
            images[url] = store.image(for: url)
            loading.remove(url)
        }
        while loading.count < 4, let url = pending.popFirst() {
            loading.insert(url)
            store.request(url)
        }
        guard loading.isEmpty else { return }
        store.changed = nil
        completion(Result {
            try PDFExporter.write(snapshot, title: title, images: images, to: destination)
        })
    }
}

enum PDFExporter {
    static func write(_ snapshot: MarkdownSnapshot, title: String, images: [URL: NSImage], to destination: URL) throws {
        let bytes = NSMutableData()
        var paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: bytes),
              let context = CGContext(consumer: consumer, mediaBox: &paper,
                                      [kCGPDFContextTitle: title] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let page = PDFPageWriter(context: context, paper: paper)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            page.begin()
            render(snapshot, images: images, on: page)
            page.end()
        }
        context.closePDF()
        try (bytes as Data).write(to: destination, options: .atomic)
    }

    private enum Block {
        case table(MarkdownTable)
        case image(MarkdownImage, after: Int)

        var offset: Int {
            switch self {
            case let .table(table): return table.range.location
            case let .image(_, after): return after
            }
        }
    }

    private static func render(_ snapshot: MarkdownSnapshot, images: [URL: NSImage], on page: PDFPageWriter) {
        let source = snapshot.source as NSString
        let styled = NSTextStorage(string: snapshot.source)
        let size: CGFloat = 12
        MarkdownAppearance.apply(snapshot, to: styled, size: size, selections: [])
        let presentation = snapshot.presentation(selections: [])
        var hidden = presentation.hidden
        var blocks = snapshot.tables.map { Block.table($0) }
        for image in snapshot.images {
            hidden.insert(integersIn: image.range.location..<NSMaxRange(image.range))
            blocks.append(.image(image, after: NSMaxRange(source.lineRange(for: image.range))))
        }

        func drawText(_ range: NSRange) {
            guard range.length > 0 else { return }
            let text = NSMutableAttributedString(attributedString: styled.attributedSubstring(from: range))
            for (offset, character) in presentation.replacements where NSLocationInRange(offset, range) {
                text.replaceCharacters(in: NSRange(location: offset - range.location, length: 1),
                                       with: String(UnicodeScalar(character)!))
            }
            let visibleRange = range.location..<NSMaxRange(range)
            for hiddenRange in hidden.rangeView.reversed() {
                let overlap = hiddenRange.clamped(to: visibleRange)
                if !overlap.isEmpty {
                    text.deleteCharacters(in: NSRange(location: overlap.lowerBound - range.location, length: overlap.count))
                }
            }
            page.draw(text)
        }

        // Images come before a table starting at the end of the same source line.
        let ordered = blocks.enumerated().sorted {
            if $0.element.offset != $1.element.offset { return $0.element.offset < $1.element.offset }
            if case .image = $0.element, case .table = $1.element { return true }
            if case .table = $0.element, case .image = $1.element { return false }
            return $0.offset < $1.offset
        }
        var cursor = 0
        for (_, block) in ordered {
            if block.offset > cursor {
                drawText(NSRange(location: cursor, length: block.offset - cursor))
                cursor = block.offset
            }
            switch block {
            case .table(let table):
                page.draw(TableLayout(table: table, source: snapshot.source, size: size, width: page.width, editing: nil))
                cursor = NSMaxRange(table.range)
            case .image(let image, _):
                if let url = image.url, let loaded = images[url] { page.draw(loaded) }
                else {
                    let label = image.alt.isEmpty ? "图片无法加载" : "图片无法加载 · \(image.alt)"
                    page.draw(NSAttributedString(string: label, attributes: MarkdownAppearance.base(size: size)))
                }
            }
        }
        drawText(NSRange(location: cursor, length: source.length - cursor))
    }
}

private final class PDFPageWriter {
    private let context: CGContext
    private let paper: CGRect
    private let margin: CGFloat = 44
    private var y: CGFloat = 0
    var width: CGFloat { paper.width - margin * 2 }
    private var height: CGFloat { paper.height - margin * 2 }

    init(context: CGContext, paper: CGRect) {
        self.context = context
        self.paper = paper
    }

    func begin() {
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        context.translateBy(x: margin, y: paper.height - margin)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        y = 0
    }

    func end() {
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }

    private func fit(_ itemHeight: CGFloat) {
        if y > 0 && y + itemHeight > height {
            end()
            begin()
        }
    }

    func draw(_ text: NSAttributedString) {
        guard text.length > 0 else { return }
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, range, _ in
            self.fit(ceil(used.height))
            let origin = NSPoint(x: 0, y: self.y - rect.minY)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            self.y += ceil(rect.height)
        }
    }

    func draw(_ image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(1, width / image.size.width, height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        fit(size.height)
        image.draw(in: NSRect(origin: NSPoint(x: 0, y: y), size: size), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        y += size.height + 8
    }

    func draw(_ table: TableLayout) {
        let grid = TableGridView()
        grid.update(table, index: 0)
        let widthScale = min(1, width / table.width)
        let hasBody = table.heights.count > 1
        let headerScale = min(widthScale, (hasBody ? height * 0.35 : height) / table.heights[0])
        func row(_ index: Int, verticalScale: CGFloat) {
            var x: CGFloat = 0
            let first = index * table.table.columnCount
            for cell in grid.cells[first..<(first + table.table.columnCount)] {
                context.saveGState()
                context.translateBy(x: x, y: y)
                context.scaleBy(x: widthScale, y: verticalScale)
                cell.draw(cell.bounds)
                context.restoreGState()
                x += cell.bounds.width * widthScale
            }
            y += table.heights[index] * verticalScale
        }

        let headerHeight = table.heights[0] * headerScale
        let bodyScales = table.heights.dropFirst().map { min(widthScale, (height - headerHeight) / $0) }
        let firstBodyHeight = hasBody ? table.heights[1] * bodyScales[0] : 0
        fit(headerHeight + firstBodyHeight)
        row(0, verticalScale: headerScale)
        for (index, scale) in bodyScales.enumerated() {
            let rowIndex = index + 1
            if y + table.heights[rowIndex] * scale > height + 0.01 {
                Palette.tableBorder.setFill()
                NSRect(x: 0, y: y - widthScale, width: table.width * widthScale, height: widthScale).fill()
                end()
                begin()
                row(0, verticalScale: headerScale)
            }
            row(rowIndex, verticalScale: scale)
        }
        y += 8
    }
}
