import AppKit

/// Exact source coordinates for a GFM pipe table. Edits replace a cell or a row, not the document.
struct MarkdownTable {
    struct Cell {
        let range: NSRange
        let source: String
    }
    struct Row {
        let range: NSRange
        let cells: [Cell]
    }
    let range: NSRange
    let separator: NSRange
    let rows: [Row]
    let alignments: [NSTextAlignment]
    var columnCount: Int { alignments.count }

    init?(source: String, seed: NSRange) {
        let text = source as NSString
        guard text.length > 0 else { return nil }
        var header = text.lineRange(for: NSRange(location: seed.location, length: 0))
        // Empty header cells may have no attributed runs. Locate their delimiter above the first run.
        func following(_ line: NSRange) -> NSRange? {
            NSMaxRange(line) < text.length ? text.lineRange(for: NSRange(location: NSMaxRange(line), length: 0)) : nil
        }
        func isDelimiter(_ line: NSRange) -> Bool {
            let cells = Self.cells(in: line, text: text)
            return !cells.isEmpty && cells.allSatisfy {
                $0.source.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil
            }
        }
        if following(header).map(isDelimiter) != true {
            var cursor = header.location
            var found: NSRange?
            while cursor > 0 {
                let previous = text.lineRange(for: NSRange(location: cursor - 1, length: 0))
                if isDelimiter(previous), previous.location > 0 {
                    found = text.lineRange(for: NSRange(location: previous.location - 1, length: 0))
                    break
                }
                if !text.substring(with: previous).contains("|") { break }
                cursor = previous.location
            }
            guard let found else { return nil }
            header = found
        }
        guard let separator = following(header), isDelimiter(separator) else { return nil }
        let headerCells = Self.cells(in: header, text: text)
        let markers = Self.cells(in: separator, text: text)
        guard !headerCells.isEmpty, headerCells.count == markers.count else { return nil }
        var rows = [Row(range: header, cells: headerCells)]
        var last = separator
        while let next = following(last) {
            let cells = Self.cells(in: next, text: text)
            guard !cells.isEmpty else { break }
            // Preserve surplus cells as source rather than silently hiding data.
            guard cells.count <= markers.count else { return nil }
            var padded = cells
            let end = Self.contentEnd(next, text: text)
            let insertion = end > next.location && text.character(at: end - 1) == 124 ? end - 1 : end
            while padded.count < markers.count {
                padded.append(Cell(range: NSRange(location: insertion, length: 0), source: ""))
            }
            rows.append(Row(range: next, cells: padded))
            last = next
        }
        self.range = NSUnionRange(header, last)
        self.separator = separator
        self.rows = rows
        self.alignments = markers.map {
            if $0.source.hasPrefix(":") && $0.source.hasSuffix(":") { return .center }
            return $0.source.hasSuffix(":") ? .right : .left
        }
    }

    static func contentEnd(_ line: NSRange, text: NSString) -> Int {
        var end = NSMaxRange(line)
        while end > line.location && [10, 13].contains(text.character(at: end - 1)) { end -= 1 }
        return end
    }

    static func cells(in line: NSRange, text: NSString) -> [Cell] {
        var start = line.location
        var end = contentEnd(line, text: text)
        while start < end && [32, 9].contains(text.character(at: start)) { start += 1 }
        while end > start && [32, 9].contains(text.character(at: end - 1)) { end -= 1 }
        guard start < end else { return [] }
        // Tables nested in block quotes/lists are left as source until those containers are supported.
        if text.character(at: start) == 62 { return [] }
        var delimiters: [Int] = []
        var backslashes = 0
        for i in start..<end {
            let c = text.character(at: i)
            if c == 124 && backslashes % 2 == 0 { delimiters.append(i) }
            backslashes = c == 92 ? backslashes + 1 : 0
        }
        guard !delimiters.isEmpty else { return [] }
        if delimiters.first == start { start += 1; delimiters.removeFirst() }
        if delimiters.last == end - 1 { end -= 1; delimiters.removeLast() }
        var result: [Cell] = []
        for boundary in delimiters + [end] {
            var a = start
            var b = boundary
            while a < b && [32, 9].contains(text.character(at: a)) { a += 1 }
            while b > a && [32, 9].contains(text.character(at: b - 1)) { b -= 1 }
            let range = NSRange(location: a, length: b - a)
            result.append(Cell(range: range, source: text.substring(with: range)))
            start = boundary + 1
        }
        return result
    }

    /// Cells remain single source lines. Literal pipes cannot accidentally create columns.
    static func safeCellSource(_ value: String) -> String {
        let value = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
        var output = ""
        var backslashes = 0
        for character in value {
            if character == "|" && backslashes % 2 == 0 { output += "\\" }
            output.append(character)
            backslashes = character == "\\" ? backslashes + 1 : 0
        }
        return output
    }

    func cellEdit(row: Int, column: Int, value: String, source: String) -> (NSRange, String, NSRange) {
        let cell = rows[row].cells[column]
        let existing = Self.cells(in: rows[row].range, text: source as NSString)
        let safe = Self.safeCellSource(value)
        if column < existing.count {
            return (cell.range, safe, NSRange(location: cell.range.location, length: safe.utf16.count))
        }
        // A short Markdown row may omit trailing cells; materialize only when one is edited.
        var values = rows[row].cells.map(\.source)
        values[column] = Self.safeCellSource(value)
        let raw = (source as NSString).substring(with: rows[row].range)
        let ending = raw.hasSuffix("\r\n") ? "\r\n" : raw.hasSuffix("\n") ? "\n" : raw.hasSuffix("\r") ? "\r" : ""
        let prefix = "| " + values.prefix(column).joined(separator: " | ") + (column > 0 ? " | " : "")
        return (rows[row].range, "| " + values.joined(separator: " | ") + " |" + ending,
                NSRange(location: rows[row].range.location + prefix.utf16.count, length: safe.utf16.count))
    }

    func newRow(after row: Int, source: String) -> (NSRange, String) {
        let line = row == 0 ? separator : rows[row].range
        let raw = (source as NSString).substring(with: line)
        let newline = source.contains("\r\n") ? "\r\n" : "\n"
        let needsBreak = !raw.hasSuffix("\n") && !raw.hasSuffix("\r")
        return (NSRange(location: NSMaxRange(line), length: 0),
                (needsBreak ? newline : "") + "| " + Array(repeating: "", count: columnCount).joined(separator: " | ") + " |" + newline)
    }
}

extension MarkdownAppearance {
    static func cellParagraph(size: CGFloat, alignment: NSTextAlignment) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = size * 1.6
        style.maximumLineHeight = size * 1.6
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func cell(_ source: String, size: CGFloat, header: Bool, alignment: NSTextAlignment) -> NSAttributedString {
        let source = source.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let style = cellParagraph(size: size, alignment: alignment)
        let regular = bodyFont(size: size)
        let font = header ? NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask) : regular
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.text, .paragraphStyle: style]
        guard let parsed = try? AttributedString(markdown: source,
                 options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: source, attributes: base)
        }
        let result = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attrs = base
            var styled = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                styled = .monospacedSystemFont(ofSize: size * 0.92, weight: .regular)
                attrs[.backgroundColor] = Palette.code
            }
            if intent.contains(.stronglyEmphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { styled = NSFontManager.shared.convert(styled, toHaveTrait: .italicFontMask) }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.link != nil { attrs[.foregroundColor] = Palette.accent; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            attrs[.font] = styled
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return result
    }
}
