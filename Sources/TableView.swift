import AppKit

/// This nested scroll view owns horizontal movement only. Vertical wheel and
/// trackpad momentum belong to the document, even while a cell is being edited.
final class TableScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let horizontal = hasHorizontalScroller &&
            (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift))
        if horizontal { super.scrollWheel(with: event) }
        else { superview?.enclosingScrollView?.scrollWheel(with: event) }
    }
}

struct TableAddress: Equatable {
    let table: Int
    let row: Int
    let column: Int
}

enum TableStyle {
    static let horizontalPadding: CGFloat = 13
    static let verticalPadding: CGFloat = 6
    static let minimumRowHeight: CGFloat = 38
}

struct TableLayout {
    var table: MarkdownTable
    let raw: String
    let size: CGFloat
    let availableWidth: CGFloat
    let editing: TableAddress?
    let contents: [[NSAttributedString]]
    let widths: [CGFloat]
    let heights: [CGFloat]
    let contentHeights: [[CGFloat]]
    var width: CGFloat { widths.reduce(0, +) }
    var gridHeight: CGFloat { heights.reduce(0, +) }
    var scrollHeight: CGFloat { width > availableWidth + 1 ? 16 : 1 }
    var height: CGFloat { gridHeight + scrollHeight }

    init(table: MarkdownTable, source: String, size: CGFloat, width: CGFloat, editing: TableAddress?) {
        self.table = table
        self.raw = (source as NSString).substring(with: table.range)
        self.size = size
        self.availableWidth = width
        self.editing = editing
        let fontSize = size
        contents = table.rows.enumerated().map { r, row in
            row.cells.enumerated().map { c, cell in
                MarkdownAppearance.cell(cell.source, size: fontSize, header: r == 0, alignment: table.alignments[c])
            }
        }
        let padding = TableStyle.horizontalPadding * 2
        var minimum = Array(repeating: ceil(fontSize * 3 + padding), count: table.columnCount)
        var desired = minimum
        let tokens = try! NSRegularExpression(pattern: #"[\x21-\x7E]+"#)
        for c in 0..<table.columnCount {
            var longest: CGFloat = 0
            for row in contents {
                let value = row[c]
                longest = max(longest, value.size().width)
                // Preserve complete numbers and short Latin tokens using their rendered font.
                for token in tokens.matches(in: value.string, range: NSRange(location: 0, length: value.length)) {
                    let measured = value.attributedSubstring(from: token.range).size().width
                    minimum[c] = max(minimum[c], min(220, ceil(measured) + padding + 2))
                }
            }
            desired[c] = max(minimum[c], ceil(longest) + padding)
        }
        // Share width in proportion to natural content, keeping each column's minimum.
        // A fixed maximum for every column used to make very different text lengths nearly equal.
        let total = max(floor(width), minimum.reduce(0, +))
        var remaining = total
        var pending = Array(minimum.indices)
        var widths = Array(repeating: CGFloat(0), count: table.columnCount)
        while !pending.isEmpty {
            let weight = pending.reduce(CGFloat(0)) { $0 + desired[$1] }
            let constrained = pending.filter { remaining * desired[$0] / weight < minimum[$0] }
            if constrained.isEmpty {
                for c in pending { widths[c] = floor(remaining * desired[c] / weight) }
                break
            }
            for c in constrained { widths[c] = minimum[c]; remaining -= minimum[c] }
            pending.removeAll { constrained.contains($0) }
        }
        if let widest = desired.indices.max(by: { desired[$0] < desired[$1] }) {
            widths[widest] += total - widths.reduce(0, +)
        }
        self.widths = widths
        var heights: [CGFloat] = []
        var contentHeights: [[CGFloat]] = []
        for (r, row) in contents.enumerated() {
            var height = TableStyle.minimumRowHeight
            var measuredCells: [CGFloat] = []
            for (c, value) in row.enumerated() {
                let available = max(20, widths[c] - padding)
                let measured = value.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                measuredCells.append(ceil(measured))
                height = max(height, ceil(measured) + TableStyle.verticalPadding * 2)
                if editing?.row == r && editing?.column == c {
                    let raw = NSAttributedString(string: table.rows[r].cells[c].source,
                        attributes: [.font: MarkdownAppearance.bodyFont(size: fontSize),
                                     .paragraphStyle: MarkdownAppearance.cellParagraph(size: fontSize, alignment: table.alignments[c])])
                    height = max(height, ceil(raw.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + TableStyle.verticalPadding * 2)
                }
            }
            heights.append(height)
            contentHeights.append(measuredCells)
        }
        self.heights = heights
        self.contentHeights = contentHeights
    }

    func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: widths.prefix(column).reduce(0, +), y: heights.prefix(row).reduce(0, +),
               width: widths[column], height: heights[row])
    }
}

final class TableCellView: NSView {
    var content = NSAttributedString(string: "")
    var header = false
    var alternate = false
    var lastRow = false
    var lastColumn = false
    var contentHeight: CGFloat = 0
    var address = TableAddress(table: 0, row: 0, column: 0)
    weak var coordinator: TableCoordinator?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        (header || alternate ? Palette.tableStripe : Palette.paper).setFill()
        bounds.fill()
        // Each shared edge has one owner, producing a continuous single-line grid.
        Palette.tableBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        if lastRow { NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill() }
        if lastColumn { NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill() }
        let inset = TableStyle.horizontalPadding
        let y = max(TableStyle.verticalPadding, floor((bounds.height - contentHeight) / 2))
        content.draw(with: NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: contentHeight),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func mouseDown(with event: NSEvent) { coordinator?.beginEditing(address) }
    override func menu(for event: NSEvent) -> NSMenu? { coordinator?.menu(for: address) }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "第 \(address.row + 1) 行，第 \(address.column + 1) 列：\(content.string.isEmpty ? "空单元格" : content.string)" }
    override func accessibilityHelp() -> String? { "点击编辑单元格；Tab 移到下一格。" }
    override func accessibilityPerformPress() -> Bool { coordinator?.beginEditing(address); return true }
}

final class TableGridView: NSView {
    override var isFlipped: Bool { true }
    var cells: [TableCellView] = []
    weak var coordinator: TableCoordinator?
    func update(_ layout: TableLayout, index: Int) {
        let count = layout.table.rows.count * layout.table.columnCount
        while cells.count > count { cells.removeLast().removeFromSuperview() }
        while cells.count < count {
            let cell = TableCellView()
            cell.coordinator = coordinator
            cells.append(cell)
            addSubview(cell)
        }
        for (r, row) in layout.contents.enumerated() {
            for (c, value) in row.enumerated() {
                let cell = cells[r * layout.table.columnCount + c]
                cell.frame = layout.cellRect(row: r, column: c)
                cell.content = value
                cell.header = r == 0
                cell.alternate = r % 2 == 0
                cell.lastRow = r == layout.contents.count - 1
                cell.lastColumn = c == row.count - 1
                cell.contentHeight = layout.contentHeights[r][c]
                cell.address = TableAddress(table: index, row: r, column: c)
                cell.needsDisplay = true
            }
        }
        frame.size = NSSize(width: layout.width, height: layout.gridHeight)
    }
}

final class TableCellEditor: NSTextView {
    weak var coordinator: TableCoordinator?
    override var undoManager: UndoManager? { coordinator?.editor?.undoManager }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let coordinator, let address = coordinator.active {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in coordinator.menu(for: address).items {
                menu.addItem(item.copy() as! NSMenuItem)
            }
        }
        return menu
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            coordinator?.insertRow()
            return
        }
        super.keyDown(with: event)
    }
}

/// Owns table presentation and the one active native cell editor. The document's source remains authoritative.
final class TableCoordinator: NSObject, NSTextViewDelegate {
    weak var editor: WritingTextView?
    var refresh: (() -> Void)?
    private(set) var layouts: [TableLayout] = []
    private var scrollViews: [NSScrollView] = []
    private var grids: [TableGridView] = []
    private(set) var active: TableAddress?
    private(set) var cellEditor: TableCellEditor?
    private var source = ""
    private var committedCell = ""
    private var committedSource = ""
    private var ownedCellRange: NSRange?
    private var updating = false
    private var positioning = false
    private var menuAddress: TableAddress?

    init(editor: WritingTextView) { self.editor = editor }

    func prepare(snapshot: MarkdownSnapshot, size: CGFloat) {
        guard let editor else { return }
        source = snapshot.source
        let width = editor.contentColumn.width
        let previous = layouts
        layouts = snapshot.tables.enumerated().map { index, table in
            let edit = active?.table == index ? active : nil
            let raw = (source as NSString).substring(with: table.range)
            if previous.indices.contains(index), previous[index].raw == raw,
               previous[index].availableWidth == width, previous[index].size == size,
               previous[index].editing == edit {
                var kept = previous[index]
                kept.table = table
                return kept
            }
            return TableLayout(table: table, source: source, size: size, width: width, editing: edit)
        }
        if let address = active, !valid(address) { finishEditing(refresh: false) }
        while grids.count > layouts.count {
            grids.removeLast()
            scrollViews.removeLast().removeFromSuperview()
        }
        while grids.count < layouts.count {
            let scroll = TableScrollView()
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = false
            scroll.scrollerStyle = .legacy
            scroll.autohidesScrollers = true
            let grid = TableGridView()
            grid.coordinator = self
            scroll.documentView = grid
            editor.addSubview(scroll)
            grids.append(grid)
            scrollViews.append(scroll)
        }
        for (i, layout) in layouts.enumerated() {
            scrollViews[i].hasHorizontalScroller = layout.width > width + 1
            grids[i].update(layout, index: i)
        }
        if let address = active, let field = cellEditor, valid(address), !field.hasMarkedText() {
            let raw = layouts[address.table].table.rows[address.row].cells[address.column].source
            if source != committedSource {
                ownedCellRange = layouts[address.table].table.rows[address.row].cells[address.column].range
                committedSource = source
                let selection = field.selectedRange()
                field.string = raw
                field.setSelectedRange(NSRange(location: min(selection.location, raw.utf16.count), length: 0))
                committedCell = raw
            }
        }
    }

    func configureStorage(_ storage: NSTextStorage) -> (IndexSet, [Int: CGFloat]) {
        let ns = source as NSString
        var hidden = IndexSet()
        var metrics: [Int: CGFloat] = [:]
        storage.beginEditing()
        for layout in layouts {
            storage.setAttributes([.font: NSFont.systemFont(ofSize: 1), .foregroundColor: NSColor.clear],
                                  range: layout.table.range)
            for (i, row) in layout.table.rows.enumerated() {
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = layout.heights[i]
                style.maximumLineHeight = layout.heights[i]
                storage.addAttribute(.paragraphStyle, value: style, range: row.range)
                metrics[row.range.location] = layout.heights[i]
            }
            let separatorStyle = NSMutableParagraphStyle()
            separatorStyle.minimumLineHeight = layout.scrollHeight
            separatorStyle.maximumLineHeight = layout.scrollHeight
            storage.addAttribute(.paragraphStyle, value: separatorStyle, range: layout.table.separator)
            metrics[layout.table.separator.location] = layout.scrollHeight
            for i in layout.table.range.location..<NSMaxRange(layout.table.range) where ![10, 13].contains(ns.character(at: i)) {
                hidden.insert(i)
            }
        }
        storage.endEditing()
        return (hidden, metrics)
    }

    func positionViews() {
        guard !positioning, let editor, let manager = editor.layoutManager, let container = editor.textContainer,
              manager.textStorage?.string == source else { return }
        positioning = true
        defer { positioning = false }
        manager.ensureLayout(for: container)
        for (i, layout) in layouts.enumerated() {
            let glyph = manager.glyphIndexForCharacter(at: layout.table.range.location)
            let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let frame = NSRect(x: editor.contentColumn.minX, y: editor.textContainerOrigin.y + rect.minY,
                               width: layout.availableWidth, height: layout.height)
            if scrollViews[i].frame != frame { scrollViews[i].frame = frame }
        }
        if let address = active, valid(address), let field = cellEditor {
            field.frame = layouts[address.table].cellRect(row: address.row, column: address.column).insetBy(dx: 1, dy: 1)
            let inset = TableStyle.horizontalPadding - 1
            let width = max(20, field.bounds.width - inset * 2)
            let measured = field.attributedString().boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            field.textContainerInset = NSSize(width: inset, height: max(TableStyle.verticalPadding - 1,
                                                                       floor((field.bounds.height - ceil(measured)) / 2)))
            field.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
    }

    func valid(_ address: TableAddress) -> Bool {
        layouts.indices.contains(address.table) && layouts[address.table].table.rows.indices.contains(address.row)
            && (0..<layouts[address.table].table.columnCount).contains(address.column)
    }

    func beginEditing(_ address: TableAddress) {
        guard valid(address), let editor else { return }
        if active == address { editor.window?.makeFirstResponder(cellEditor); return }
        finishEditing(refresh: false)
        active = address
        let cell = layouts[address.table].table.rows[address.row].cells[address.column]
        committedCell = cell.source
        committedSource = editor.string
        let actualCells = MarkdownTable.cells(in: layouts[address.table].table.rows[address.row].range, text: editor.string as NSString)
        ownedCellRange = address.column < actualCells.count ? cell.range : nil
        let field = TableCellEditor(frame: .zero)
        field.coordinator = self
        field.delegate = self
        field.isRichText = false
        field.allowsUndo = false // The source editor registers each change once in the document's undo manager.
        let font = MarkdownAppearance.bodyFont(size: layouts[address.table].size)
        let paragraph = MarkdownAppearance.cellParagraph(size: layouts[address.table].size,
                                                         alignment: layouts[address.table].table.alignments[address.column])
        field.font = font
        field.textColor = Palette.text
        field.defaultParagraphStyle = paragraph
        field.typingAttributes = [.font: font, .foregroundColor: Palette.text, .paragraphStyle: paragraph]
        field.textContainer?.lineFragmentPadding = 0
        field.textContainerInset = NSSize(width: TableStyle.horizontalPadding - 1, height: TableStyle.verticalPadding - 1)
        field.isVerticallyResizable = false
        field.isHorizontallyResizable = false
        field.textContainer?.widthTracksTextView = true
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isContinuousSpellCheckingEnabled = false
        field.backgroundColor = Palette.paper
        field.insertionPointColor = Palette.accent
        field.wantsLayer = true
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = Palette.accent.cgColor
        field.string = cell.source
        field.setAccessibilityLabel("表格单元格，第 \(address.row + 1) 行，第 \(address.column + 1) 列")
        cellEditor = field
        grids[address.table].addSubview(field)
        refresh?()
        positionViews()
        editor.window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
        grids[address.table].scrollToVisible(field.frame)
    }

    func finishEditing(refresh shouldRefresh: Bool = true) {
        guard let field = cellEditor else { return }
        if field.hasMarkedText() { field.unmarkText(); textDidChange(Notification(name: NSText.didChangeNotification, object: field)) }
        cellEditor = nil
        active = nil
        ownedCellRange = nil
        committedSource = ""
        field.delegate = nil
        field.removeFromSuperview()
        if shouldRefresh { refresh?() }
    }

    func textDidChange(_ notification: Notification) {
        guard !updating, let field = cellEditor, !field.hasMarkedText(), let address = active, valid(address), let editor else { return }
        let safe = MarkdownTable.safeCellSource(field.string)
        if safe != field.string {
            let selection = field.selectedRange()
            let added = safe.utf16.count - field.string.utf16.count
            field.string = safe
            field.setSelectedRange(NSRange(location: min(max(0, selection.location + added), safe.utf16.count), length: 0))
        }
        guard safe != committedCell else { return }
        let edit: (NSRange, String, NSRange)
        if let owned = ownedCellRange, committedSource == editor.string {
            edit = (owned, safe, NSRange(location: owned.location, length: safe.utf16.count))
        } else {
            edit = layouts[address.table].table.cellEdit(row: address.row, column: address.column, value: safe, source: editor.string)
        }
        updating = true
        committedCell = safe
        ownedCellRange = edit.2
        committedSource = (editor.string as NSString).replacingCharacters(in: edit.0, with: edit.1)
        editor.insertText(edit.1, replacementRange: edit.0)
        updating = false
        // Reparse immediately so the next keystroke never uses stale cell coordinates.
        (editor.delegate as? EditorWindowController)?.refreshSourcePresentation()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "insertTab:": moveCell(1); return true
        case "insertBacktab:": moveCell(-1); return true
        case "insertNewline:", "cancelOperation:":
            let end = active.map { NSMaxRange(layouts[$0.table].table.range) }
            finishEditing()
            if let end { editor?.setSelectedRange(NSRange(location: min(end, editor?.string.utf16.count ?? 0), length: 0)) }
            editor?.window?.makeFirstResponder(editor)
            return true
        case "insertLineBreak:": textView.insertText("<br>", replacementRange: textView.selectedRange()); return true
        default: return false
        }
    }

    func moveCell(_ delta: Int) {
        guard let address = active, valid(address) else { return }
        let table = layouts[address.table].table
        let next = address.row * table.columnCount + address.column + delta
        if next >= table.rows.count * table.columnCount { insertRow(); return }
        guard next >= 0 else { return }
        beginEditing(TableAddress(table: address.table, row: next / table.columnCount, column: next % table.columnCount))
    }

    func enterSelectedCell() {
        guard active == nil, let editor, editor.window?.firstResponder === editor, editor.selectedRange().length == 0 else { return }
        let location = editor.selectedRange().location
        for (t, layout) in layouts.enumerated() where NSLocationInRange(location, layout.table.range) {
            let row = layout.table.rows.firstIndex { NSLocationInRange(location, $0.range) } ?? 0
            let cells = layout.table.rows[row].cells
            let column = cells.firstIndex { location <= NSMaxRange($0.range) } ?? cells.count - 1
            beginEditing(TableAddress(table: t, row: row, column: column))
            return
        }
    }

    func insertRow() {
        guard let address = active ?? menuAddress, valid(address), let editor else { return }
        let edit = layouts[address.table].table.newRow(after: address.row, source: editor.string)
        finishEditing(refresh: false)
        editor.insertText(edit.1, replacementRange: edit.0)
        (editor.delegate as? EditorWindowController)?.refreshSourcePresentation()
        beginEditing(TableAddress(table: address.table, row: address.row + 1, column: 0))
    }

    func menu(for address: TableAddress) -> NSMenu {
        menuAddress = address
        let menu = NSMenu()
        for (title, tag) in [("编辑单元格", 0), ("在下方插入行", 1), ("删除当前行", 2),
                             ("在左侧插入列", 3), ("在右侧插入列", 4), ("删除当前列", 5),
                             ("此列左对齐", 6), ("此列居中", 7), ("此列右对齐", 8)] {
            let item = NSMenuItem(title: title, action: #selector(tableAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.isEnabled = !(tag == 2 && address.row == 0) && !(tag == 5 && layouts[address.table].table.columnCount == 1)
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        return menu
    }

    @objc private func tableAction(_ sender: NSMenuItem) {
        guard let address = menuAddress, valid(address), let editor else { return }
        if sender.tag == 0 { beginEditing(address); return }
        if sender.tag == 1 { finishEditing(refresh: false); insertRow(); return }
        let table = layouts[address.table].table
        let newline = editor.string.contains("\r\n") ? "\r\n" : "\n"
        var range = table.range
        var value = ""
        if sender.tag == 2 {
            guard address.row > 0 else { return }
            range = table.rows[address.row].range
        } else {
            var values = table.rows.map { $0.cells.map(\.source) }
            var markers = table.alignments.map { $0 == .right ? "---:" : $0 == .center ? ":---:" : "---" }
            if sender.tag == 3 || sender.tag == 4 {
                let column = address.column + (sender.tag == 4 ? 1 : 0)
                for r in values.indices { values[r].insert("", at: column) }
                markers.insert("---", at: column)
            } else if sender.tag == 5 {
                guard table.columnCount > 1 else { return }
                for r in values.indices { values[r].remove(at: address.column) }
                markers.remove(at: address.column)
            } else { markers[address.column] = sender.tag == 8 ? "---:" : sender.tag == 7 ? ":---:" : "---" }
            var lines = values.map { "| " + $0.joined(separator: " | ") + " |" }
            lines.insert("|" + markers.joined(separator: "|") + "|", at: 1)
            let raw = (editor.string as NSString).substring(with: table.range)
            value = lines.joined(separator: newline) + (raw.hasSuffix("\n") || raw.hasSuffix("\r") ? newline : "")
        }
        finishEditing(refresh: false)
        editor.insertText(value, replacementRange: range)
        (editor.delegate as? EditorWindowController)?.refreshSourcePresentation()
    }
}
