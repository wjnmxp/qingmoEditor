import AppKit

enum Palette {
    static let accent = NSColor(calibratedRed: 0.19, green: 0.43, blue: 0.39, alpha: 1)
    static let paper = NSColor(name: "Paper") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.115, alpha: 1)
            : NSColor.white
    }
    static let sidebar = NSColor(name: "Sidebar") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(srgbRed: 0.969, green: 0.969, blue: 0.969, alpha: 1)
    }
    static let text = NSColor(name: "ReadingText") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.86, green: 0.86, blue: 0.86, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.20, blue: 0.20, alpha: 1)
    }
    static let tableStripe = NSColor(name: "TableStripe") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.15, alpha: 1)
            : NSColor(srgbRed: 248.0 / 255, green: 248.0 / 255, blue: 248.0 / 255, alpha: 1)
    }
    static let tableBorder = NSColor(name: "TableBorder") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.28, alpha: 1)
            : NSColor(srgbRed: 223.0 / 255, green: 226.0 / 255, blue: 229.0 / 255, alpha: 1)
    }
    static let code = NSColor.quaternaryLabelColor.withAlphaComponent(0.10)
}

struct Heading {
    let title: String
    let level: Int
    let range: NSRange
}

/// A presentation of the original UTF-16 source, never a replacement for that source.
/// Foundation owns Markdown interpretation; its source positions also drive the outline.
struct MarkdownSnapshot {
    struct Span {
        let range: NSRange
        let inline: InlinePresentationIntent
        let link: URL?
    }
    struct Block {
        let identity: Int
        var range: NSRange
        var title = ""
        var heading: Int?
        var code = false
        var table = false
        var quote = false
        var list = false
        var image = false
        var link = false
        var covered = IndexSet()
        var hidden = IndexSet()
        var replacements: [Int: UniChar] = [:]
        var fenceLines: [NSRange] = []
    }
    let source: String
    let spans: [Span]
    let blocks: [Block]
    let headings: [Heading]
    let tables: [MarkdownTable]
    let images: [MarkdownImage]

    init(_ source: String, baseURL: URL? = nil) {
        self.source = source
        let text = source as NSString
        guard !source.isEmpty,
              let parsed = try? AttributedString(markdown: source, options:
                .init(interpretedSyntax: .full, failurePolicy: .throwError, appliesSourcePositionAttributes: true),
                baseURL: baseURL) else {
            spans = []; blocks = []; headings = []; tables = []; images = []
            return
        }
        var spans: [Span] = []
        var blocks: [Block] = []
        var indexes: [Int: Int] = [:]
        var tableSeeds: [Int: NSRange] = [:]
        for run in parsed.runs {
            guard let position = run.markdownSourcePosition,
                  let sourceRange = Range(position, in: source),
                  let leaf = run.presentationIntent?.components.first else { continue }
            let range = NSRange(sourceRange, in: source)
            guard range.length > 0, NSMaxRange(range) <= text.length else { continue }
            let index: Int
            if let existing = indexes[leaf.identity] { index = existing }
            else {
                index = blocks.count
                indexes[leaf.identity] = index
                blocks.append(Block(identity: leaf.identity, range: range))
            }
            blocks[index].range = NSUnionRange(blocks[index].range, range)
            blocks[index].title += String(parsed[run.range].characters)
            blocks[index].covered.insert(integersIn: range.location..<NSMaxRange(range))
            blocks[index].image = blocks[index].image || run.imageURL != nil
            blocks[index].link = blocks[index].link || run.link != nil
            for component in run.presentationIntent?.components ?? [] {
                switch component.kind {
                case .header(let level): blocks[index].heading = level
                case .codeBlock: blocks[index].code = true
                case .table:
                    blocks[index].table = true
                    tableSeeds[component.identity] = tableSeeds[component.identity].map { NSUnionRange($0, range) } ?? range
                case .blockQuote: blocks[index].quote = true
                case .listItem: blocks[index].list = true
                default: break
                }
            }
            spans.append(Span(range: range, inline: run.inlinePresentationIntent ?? [], link: run.link))
        }
        let images = MarkdownImage.parse(source, baseURL: baseURL,
            excluding: blocks.filter { $0.code || $0.table }.map { text.lineRange(for: $0.range) }
                + spans.filter { $0.inline.contains(.code) }.map(\.range))
        self.images = images
        for i in blocks.indices {
            blocks[i].image = blocks[i].image || images.contains { NSIntersectionRange($0.range, blocks[i].range).length > 0 }
            blocks[i].range = text.lineRange(for: blocks[i].range)
            let range = blocks[i].range
            if blocks[i].code {
                let first = text.lineRange(for: NSRange(location: range.location, length: 0))
                let raw = text.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines)
                if let marker = raw.first, (marker == "\u{0060}" || marker == "~") {
                    let count = raw.prefix(while: { $0 == marker }).count
                    if count >= 3 {
                        blocks[i].fenceLines.append(first)
                        let last = text.lineRange(for: NSRange(location: max(range.location, NSMaxRange(range) - 1), length: 0))
                        let closing = text.substring(with: last).trimmingCharacters(in: .whitespacesAndNewlines)
                        if last != first && closing.count >= count && closing.allSatisfy({ $0 == marker }) {
                            blocks[i].fenceLines.append(last)
                        }
                        for line in blocks[i].fenceLines {
                            let content = Self.contentRange(line, in: text)
                            blocks[i].hidden.insert(integersIn: content.location..<NSMaxRange(content))
                        }
                    }
                }
                continue
            }
            // Tables have their own source-preserving grid. Images have their own previews; HTML stays visible.
            let raw = text.substring(with: range)
            if blocks[i].image || blocks[i].table ||
                raw.range(of: #"</?[A-Za-z][^>]*>"#, options: .regularExpression) != nil { continue }
            var candidates = IndexSet(integersIn: range.location..<NSMaxRange(range))
            candidates.subtract(blocks[i].covered)
            var offset = range.location
            while offset < NSMaxRange(range) {
                let line = text.lineRange(for: NSRange(location: offset, length: 0))
                let content = Self.contentRange(line, in: text)
                candidates.remove(integersIn: NSMaxRange(content)..<NSMaxRange(line))
                let rawLine = text.substring(with: content)
                // Keep list indentation and quote depth; substitute only their visible markers.
                if blocks[i].list || blocks[i].quote {
                    if let prefix = rawLine.range(of: #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|\d+[.)])[ \t]+)?"#,
                                                   options: .regularExpression) {
                        let prefixRange = NSRange(prefix, in: rawLine)
                        let end = offset + prefixRange.length
                        candidates.remove(integersIn: offset..<end)
                        for location in offset..<end {
                            let c = text.character(at: location)
                            if c == 62 { blocks[i].replacements[location] = 0x2502 }
                            else if [45, 43, 42].contains(c) { blocks[i].replacements[location] = 0x2022 }
                        }
                    }
                }
                offset = NSMaxRange(line)
            }
            for gap in candidates.rangeView {
                let gapRange = NSRange(location: gap.lowerBound, length: gap.count)
                let rawGap = text.substring(with: gapRange)
                let trimmed = rawGap.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let syntaxOnly = trimmed.allSatisfy { "*_~\u{0060}".contains($0) }
                let headingSyntax = blocks[i].heading != nil && trimmed.allSatisfy { "#=-".contains($0) }
                let linkSyntax = blocks[i].link && trimmed.contains(where: { "[]()<>".contains($0) })
                if syntaxOnly || headingSyntax || linkSyntax {
                    blocks[i].hidden.insert(integersIn: gap)
                }
            }
            // Setext underlines have no attributed run of their own.
            let prefixEnd = blocks[i].covered.first ?? range.location
            let headingPrefix = text.substring(with: NSRange(location: range.location, length: prefixEnd - range.location))
            if blocks[i].heading != nil, !headingPrefix.contains("#"), NSMaxRange(range) < text.length {
                let following = text.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                let raw = text.substring(with: following).trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty && (raw.allSatisfy { $0 == "=" } || raw.allSatisfy { $0 == "-" }) {
                    blocks[i].range = NSUnionRange(range, following)
                    blocks[i].fenceLines.append(following)
                    let content = Self.contentRange(following, in: text)
                    blocks[i].hidden.insert(integersIn: content.location..<NSMaxRange(content))
                }
            }
        }
        self.tables = tableSeeds.values.sorted { $0.location < $1.location }.compactMap { MarkdownTable(source: source, seed: $0) }
        self.spans = spans
        self.blocks = blocks
        self.headings = blocks.compactMap { block in
            guard let level = block.heading else { return nil }
            return Heading(title: block.title.isEmpty ? "未命名标题" : block.title, level: level, range: block.range)
        }
    }

    private static func contentRange(_ line: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(line)
        while end > line.location && [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    func isCode(at location: Int) -> Bool {
        blocks.contains { $0.code && NSLocationInRange(location, $0.range) }
    }

    func isActive(_ block: Block, selections: [NSRange]) -> Bool {
        selections.contains {
            $0.length == 0 ? NSLocationInRange($0.location, block.range)
                : NSIntersectionRange($0, block.range).length > 0
        }
    }

    func presentation(selections: [NSRange]) -> (hidden: IndexSet, replacements: [Int: UniChar]) {
        var hidden = IndexSet()
        var replacements: [Int: UniChar] = [:]
        for block in blocks where !isActive(block, selections: selections) {
            hidden.formUnion(block.hidden)
            replacements.merge(block.replacements) { first, _ in first }
        }
        return (hidden, replacements)
    }
}

enum MarkdownAppearance {
    static let defaultSize: CGFloat = 16

    // Helvetica Neue cascades to PingFang SC Regular, rather than the denser UI variant.
    static func bodyFont(size: CGFloat) -> NSFont {
        NSFont(name: "HelveticaNeue", size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
    }

    static func paragraph(size: CGFloat = defaultSize) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = size * 0.25
        style.paragraphSpacing = 4
        return style
    }

    static func base(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: bodyFont(size: size), .foregroundColor: Palette.text,
         .paragraphStyle: paragraph(size: size)]
    }

    static func apply(_ snapshot: MarkdownSnapshot, to storage: NSTextStorage, size: CGFloat, selections: [NSRange]) {
        storage.beginEditing()
        storage.setAttributes(base(size: size), range: NSRange(location: 0, length: storage.length))
        for block in snapshot.blocks {
            let style = paragraph(size: size)
            if let level = block.heading {
                let scale: CGFloat = level == 1 ? 1.85 : level == 2 ? 1.45 : level == 3 ? 1.22 : 1.1
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size * scale, weight: .semibold), range: block.range)
                storage.addAttribute(.foregroundColor, value: Palette.accent, range: block.range)
                style.paragraphSpacing = 8
            }
            if block.quote { storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: block.range) }
            if block.code {
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular), range: block.range)
                storage.addAttribute(.backgroundColor, value: Palette.code, range: block.range)
                style.lineSpacing = 5
            }
            if block.list { style.headIndent = 18 }
            storage.addAttribute(.paragraphStyle, value: style, range: block.range)
            for line in block.fenceLines {
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
                if !snapshot.isActive(block, selections: selections) {
                    let compact = paragraph(size: 1)
                    compact.maximumLineHeight = 5
                    compact.minimumLineHeight = 5
                    compact.lineSpacing = 0
                    compact.paragraphSpacing = 0
                    storage.addAttribute(.paragraphStyle, value: compact, range: line)
                    storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 1), range: line)
                }
            }
        }
        for span in snapshot.spans {
            var font = storage.attribute(.font, at: span.range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: size)
            if span.inline.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: size * 0.88, weight: .regular)
                storage.addAttribute(.backgroundColor, value: Palette.code, range: span.range)
            }
            if span.inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if span.inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if !span.inline.intersection([.code, .stronglyEmphasized, .emphasized]).isEmpty {
                storage.addAttribute(.font, value: font, range: span.range)
            }
            if span.inline.contains(.strikethrough) {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            }
            if let link = span.link, ["https", "http", "mailto", "file"].contains(link.scheme?.lowercased() ?? "") {
                storage.addAttribute(.link, value: link, range: span.range)
                storage.addAttribute(.foregroundColor, value: Palette.accent, range: span.range)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: span.range)
            }
        }
        storage.endEditing()
    }
}
