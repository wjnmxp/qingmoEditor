import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let documents = MarkdownDocumentController()
NSWindow.allowsAutomaticWindowTabbing = false
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    checks += 1
    print("PASS: \(message)")
}
func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
let original = "# 中文 👩🏽‍💻\r\n\r\n**文字** 与 café\r\n- [ ] 一项\r\n"
for (encoding, mark) in [(String.Encoding.utf8, Data()),
                         (.utf8, Data([0xef, 0xbb, 0xbf])),
                         (.utf16LittleEndian, Data([0xff, 0xfe])),
                         (.utf16BigEndian, Data([0xfe, 0xff]))] {
    let bytes = mark + original.data(using: encoding)!
    let (text, codec) = try FileCodec.decode(bytes)
    check(text == original, "Decoded Unicode, emoji and CRLF without loss (\(encoding.rawValue), BOM \(mark.count))")
    let encoded = try codec.encode(text)
    check(encoded == bytes, "Byte-exact round trip (\(encoding.rawValue), BOM \(mark.count))")
}
do {
    _ = try FileCodec.decode(Data([0xff, 0x80, 0x00]))
    check(false, "Malformed encoding rejected")
} catch { check(true, "Malformed encoding rejected instead of lossy saving") }

let fences = "# 真标题\n\u{0060}\u{0060}\u{0060}\u{0060}swift\n# 代码里的伪标题\n\u{0060}\u{0060}\u{0060}\n# 仍在代码里\n\u{0060}\u{0060}\u{0060}\u{0060}\n## 第二个标题\n#no-heading\n"
check(MarkdownSnapshot(fences).headings.map(\.title) == ["真标题", "第二个标题"],
      "Outline uses the parser's code-fence boundaries")
check(MarkdownSnapshot("一级标题\n=======\n\n## **二级**\n").headings.map(\.title) == ["一级标题", "二级"],
      "ATX and Setext outline share parsed heading text")

let separated = "# 标题\n---\n"
let separatorOffset = (separated as NSString).range(of: "---").location
check(!MarkdownSnapshot(separated).presentation(selections: []).hidden.contains(separatorOffset),
      "A separator after an ATX heading is not mistaken for a Setext underline")

let one = try documents.openUntitledDocumentAndDisplay(false) as! MarkdownDocument
let two = try documents.openUntitledDocumentAndDisplay(false) as! MarkdownDocument
one.makeWindowControllers()
two.makeWindowControllers()
let first = one.windowControllers[0] as! EditorWindowController
let second = two.windowControllers[0] as! EditorWindowController
check(one !== two && first.window !== second.window, "New documents own independent native windows")
check(first.window?.tabbingMode == .disallowed && second.window?.tabbingMode == .disallowed, "Windows cannot merge into tabs")
first.editor.insertText(original, replacementRange: NSRange(location: 0, length: 0))
settle()
check(one.source == original && two.source.isEmpty, "Live editing the first window does not change the second")
second.editor.insertText("第二个文档\n", replacementRange: NSRange(location: 0, length: 0))
settle()
check(one.source == original && two.source == "第二个文档\n", "Each window keeps its own contents")
let undo = two.undoManager!
check(undo.canUndo, "Native text editing registers undo")
undo.undo()
settle()
check(two.source.isEmpty, "Undo updates document model after rendering")
undo.redo()
settle()
check(two.source == "第二个文档\n", "Redo updates document model after rendering")

let layout = first.editor.layoutManager as! LiveLayoutManager
layout.ensureLayout(for: first.editor.textContainer!)
let headingGlyph = layout.glyphIndexForCharacter(at: 0)
check(layout.propertyForGlyph(at: headingGlyph).contains(.null), "Inactive heading marker takes no glyph space")
let boldRange = (original as NSString).range(of: "文字")
let boldFont = first.editor.textStorage!.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
check(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask), "Bold text renders in the editable canvas")
check(first.editor.string == original, "Live rendering preserves the exact editable source")
first.editor.setSelectedRange(NSRange(location: boldRange.location + 1, length: 0))
check(!layout.hiddenCharacters.contains(boldRange.location - 1), "Entering a paragraph reveals its editable syntax automatically")
first.editor.insertText("新", replacementRange: first.editor.selectedRange())
settle()
check(one.source.contains("**文新字**"), "Editing rendered content preserves surrounding Markdown")
one.undoManager!.undo()
settle()
check(one.source == original, "Undo restores exact source after editing a rendered paragraph")
first.editor.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
check(layout.hiddenCharacters.contains(boldRange.location - 1), "Leaving the paragraph automatically hides syntax again")

let ime = try documents.openUntitledDocumentAndDisplay(false) as! MarkdownDocument
ime.makeWindowControllers()
let input = (ime.windowControllers[0] as! EditorWindowController).editor
input.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
settle()
check(input.hasMarkedText() && input.string == "zhong", "Delayed rendering leaves IME marked text intact")
check(ime.source.isEmpty, "Uncommitted input does not enter the saved document")
input.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
settle()
check(!input.hasMarkedText() && ime.source == "中文", "Chinese composition commits to the document normally")

let sample = "# 标题 **强调**\n\n正文 *斜体* 和 **粗 *斜* 体**、[链接](https://example.com/a_(b)) 与 \u{0060}code\u{0060}。\n\n- 列表\n\n> 引用\n\n~~~swift\n- code\n~~~\n\n尾部\n"
let demo = MarkdownDocument()
demo.source = sample
demo.makeWindowControllers()
let demoEditor = (demo.windowControllers[0] as! EditorWindowController).editor
demoEditor.setSelectedRange(NSRange(location: sample.utf16.count, length: 0))
let demoLayout = demoEditor.layoutManager as! LiveLayoutManager
demoLayout.ensureLayout(for: demoEditor.textContainer!)
let rendered = String(decoding: sample.utf16.enumerated()
    .filter { !demoLayout.hiddenCharacters.contains($0.offset) }.map { $0.element }, as: UTF16.self)
check(!rendered.contains("**") && !rendered.contains("https://") && rendered.contains("链接"),
      "Nested inline styles and balanced link destinations collapse in place")
let codeRange = (sample as NSString).range(of: "- code")
let codeFont = demoEditor.textStorage!.attribute(.font, at: codeRange.location, effectiveRange: nil) as! NSFont
check(codeFont.pointSize > 10 && !demoLayout.hiddenCharacters.contains(codeRange.location),
      "Collapsing fences preserves readable code content")
demoEditor.setSelectedRange(NSRange(location: NSMaxRange(codeRange), length: 0))
demoEditor.insertNewline(nil)
check(demo.source.contains("- code\n\n~~~") && !demo.source.contains("- code\n- "), "Code blocks do not trigger list continuation")

let unsupported = "![图片](local.png)\n\n<div>文字</div>\n"
check(MarkdownSnapshot(unsupported).presentation(selections: []).hidden.isEmpty,
      "Image source remains authoritative and unsupported HTML stays editable")
let escaped = "\\*不是斜体\\* &amp;\n\nunclosed **text\n"
check(MarkdownSnapshot(escaped).presentation(selections: []).hidden.isEmpty,
      "Escapes, entities and unfinished syntax stay editable")

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qingmo-test-" + UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let firstURL = directory.appendingPathComponent("独立窗口一.md")
let secondURL = directory.appendingPathComponent("独立窗口二.md")
try one.write(to: firstURL, ofType: MarkdownDocumentController.typeName)
try two.write(to: secondURL, ofType: MarkdownDocumentController.typeName)
check(try! Data(contentsOf: firstURL) == Data(original.utf8), "First document saves exact Markdown bytes after live editing")
check(try! String(contentsOf: secondURL, encoding: .utf8) == "第二个文档\n", "Second document saves independently")
let reopened = MarkdownDocument()
try reopened.read(from: Data(contentsOf: firstURL), ofType: MarkdownDocumentController.typeName)
reopened.makeWindowControllers()
check(reopened.source == original && (reopened.windowControllers[0] as! EditorWindowController).editor.string == original,
      "Saved document reopens in live editor without data loss")

let tableSource = "# 表格验证\n\n| 项目 | 说明 | 金额 |\n|:---|:---:|---:|\n| 中文 👩🏽‍💻 | **加粗** 与 \u{0060}代码\u{0060}，长说明需要在单元格内部自动换行。 | 1,234.50 |\n| 空值 |  |  |\n| 竖线 | a\\|b | 42 |\n\n表后正文不能被覆盖。\n"
let tableDoc = MarkdownDocument()
tableDoc.source = tableSource
tableDoc.makeWindowControllers()
let tableWindow = tableDoc.windowControllers[0] as! EditorWindowController
tableWindow.window?.contentView?.layoutSubtreeIfNeeded()
settle()
let coordinator = tableWindow.tablePresentation!
check(coordinator.layouts.count == 1 && coordinator.layouts[0].table.columnCount == 3,
      "Native table recognizes three aligned columns")
check(coordinator.layouts[0].table.rows.count == 4 && coordinator.layouts[0].table.rows[2].cells[1].source.isEmpty,
      "Empty cells and rows retain their original positions")
check(coordinator.layouts[0].table.rows[3].cells[1].source == "a\\|b",
      "Escaped pipes remain inside their cell")
check(coordinator.layouts[0].table.alignments == [.left, .center, .right],
      "Markdown column alignment reaches the native grid")
let tableManager = tableWindow.editor.layoutManager!
tableManager.ensureLayout(for: tableWindow.editor.textContainer!)
let lastCellRow = coordinator.layouts[0].table.rows.last!.range
let lastLine = tableManager.lineFragmentRect(forGlyphAt: tableManager.glyphIndexForCharacter(at: lastCellRow.location), effectiveRange: nil)
let followingText = (tableSource as NSString).range(of: "表后正文")
let followingLine = tableManager.lineFragmentRect(forGlyphAt: tableManager.glyphIndexForCharacter(at: followingText.location), effectiveRange: nil)
check(lastLine.height >= coordinator.layouts[0].heights.last! && followingLine.minY >= lastLine.maxY,
      "Table reserves every wrapped row's height without covering following text")
check(tableDoc.source == tableSource, "Table rendering does not rewrite Markdown")

coordinator.beginEditing(TableAddress(table: 0, row: 1, column: 1))
let cellEditor = coordinator.cellEditor!
cellEditor.insertText("新内容 | 中文\n下一行", replacementRange: NSRange(location: 0, length: cellEditor.string.utf16.count))
settle()
check(tableDoc.source.contains("新内容 \\| 中文<br>下一行"), "Cell edits escape pipes and encode line breaks without adding columns")
check(coordinator.layouts[0].table.columnCount == 3 && coordinator.layouts[0].table.rows[2].cells[1].source.isEmpty,
      "Editing a cell preserves neighboring empty cells")
cellEditor.insertText("Hello", replacementRange: NSRange(location: 0, length: cellEditor.string.utf16.count))
cellEditor.insertText(" ", replacementRange: cellEditor.selectedRange())
cellEditor.insertText("world", replacementRange: cellEditor.selectedRange())
settle()
check(tableDoc.source.contains("| Hello world |"), "Incremental typing preserves trailing spaces between words")
cellEditor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: cellEditor.selectedRange())
settle()
check(cellEditor.hasMarkedText() && !tableDoc.source.contains("zhong"), "Table IME composition stays intact and uncommitted")
cellEditor.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
settle()
check(tableDoc.source.contains("Hello world中文"), "Chinese composition commits inside a table cell")
coordinator.moveCell(1)
check(coordinator.active == TableAddress(table: 0, row: 1, column: 2), "Tab moves to the next cell")
coordinator.finishEditing()
while tableDoc.source != tableSource && tableDoc.undoManager!.canUndo {
    tableDoc.undoManager!.undo()
    settle()
}
check(tableDoc.source == tableSource, "Cell edits undo back to byte-identical Markdown")
coordinator.beginEditing(TableAddress(table: 0, row: 1, column: 0))
coordinator.insertRow()
settle()
check(coordinator.layouts[0].table.rows.count == 5 && coordinator.active?.row == 2,
      "Insert row creates one real Markdown row and focuses its first cell")
tableDoc.undoManager!.undo()
// Escape/focus changes can arrive before the debounced source restyle after Undo.
coordinator.finishEditing()
check(coordinator.layouts[0].raw == (tableSource as NSString).substring(with: MarkdownSnapshot(tableSource).tables[0].range)
      && coordinator.layouts[0].table.rows.count == 4,
      "Immediately leaving a cell after Undo refreshes table geometry from the current source")
settle()
check(tableDoc.source == tableSource, "Structural table edits undo without touching surrounding paragraphs")
tableManager.ensureLayout(for: tableWindow.editor.textContainer!)
let restoredRow = coordinator.layouts[0].table.rows.last!.range
let restoredLine = tableManager.lineFragmentRect(forGlyphAt: tableManager.glyphIndexForCharacter(at: restoredRow.location), effectiveRange: nil)
let restoredFollowing = tableManager.lineFragmentRect(forGlyphAt: tableManager.glyphIndexForCharacter(at: followingText.location), effectiveRange: nil)
check(restoredFollowing.minY >= restoredLine.maxY,
      "Undo and immediate cell exit never leave a stale table over the following paragraph")
check(MarkdownSnapshot("~~~\n| a | b |\n|---|---|\n| c | d |\n~~~\n").tables.isEmpty,
      "Pipe syntax in a code fence never creates a rendered table")
let shortTable = MarkdownSnapshot("| a | b | c |\n|---|---|---|\n| x |\n").tables.first!
let shortEdit = shortTable.cellEdit(row: 1, column: 2, value: "新增", source: "| a | b | c |\n|---|---|---|\n| x |\n")
check(shortEdit.1.contains("| x |  | 新增 |"), "Editing a missing trailing cell materializes the missing columns safely")

if let fixturePath = CommandLine.arguments.dropFirst().first {
    let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
    let realDocument = MarkdownDocument()
    try realDocument.read(from: bytes, ofType: MarkdownDocumentController.typeName)
    realDocument.makeWindowControllers()
    let window = realDocument.windowControllers[0] as! EditorWindowController
    window.window?.contentView?.layoutSubtreeIfNeeded()
    settle()
    window.refreshSourcePresentation()
    let tables = window.tablePresentation!.layouts
    check(tables.count == 20 && tables.map { $0.table.columnCount }.max() == 8,
          "User's complete document renders all 20 tables including the 8-column budget")
    check(tables.allSatisfy { $0.heights.count == $0.table.rows.count && $0.heights.allSatisfy { $0 >= 38 } },
          "All real-document table rows have measured, nonzero cell heights")
    let eight = tables.first { $0.table.columnCount == 8 }!
    check(eight.width >= eight.availableWidth - 8 && eight.table.alignments.dropFirst().allSatisfy { $0 == .right },
          "Wide financial table preserves every right-aligned amount column")
    let amountsFit = eight.contents.dropFirst().allSatisfy { row in
        row.enumerated().dropFirst().allSatisfy { column, value in
            guard value.string.range(of: #"^[0-9,.]+$"#, options: .regularExpression) != nil else { return true }
            let storage = NSTextStorage(attributedString: value)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: eight.widths[column] - TableStyle.horizontalPadding * 2, height: 1000))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
            return lines == 1
        }
    }
    check(amountsFit, "Financial amounts, including bold totals, never split across lines in their cells")
    check(try! realDocument.data(ofType: MarkdownDocumentController.typeName) == bytes,
          "Complete user document round-trips byte-for-byte after table rendering")
}

let imageURL = directory.appendingPathComponent("中文 图片(1).png")
let testBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 240,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let png = testBitmap.representation(using: .png, properties: [:])!
try png.write(to: imageURL)
let imageMarkdown = "# 图片测试\n\n图片上方的正文。\n\n![](<中文 图片(1).png>)\n\n图片后面的正文不会被遮住。\n\n"
let imageDoc = MarkdownDocument()
imageDoc.fileURL = directory.appendingPathComponent("图片 测试.md")
imageDoc.source = imageMarkdown
imageDoc.makeWindowControllers()
let imageWindow = imageDoc.windowControllers[0] as! EditorWindowController
imageWindow.window?.contentView?.layoutSubtreeIfNeeded()
imageWindow.editor.setSelectedRange(NSRange(location: imageMarkdown.utf16.count, length: 0))
imageWindow.refreshSourcePresentation()
let imageCoordinator = imageWindow.imagePresentation!
let imageReference = MarkdownSnapshot(imageMarkdown, baseURL: directory).images.first!
check(imageReference.url?.standardizedFileURL == imageURL.standardizedFileURL && imageReference.alt.isEmpty,
      "Empty alt text and Chinese paths with spaces and parentheses resolve correctly")
imageCoordinator.store.request(imageReference.url!)
for _ in 0..<30 where imageCoordinator.store.image(for: imageReference.url!) == nil { settle() }
check(imageCoordinator.views.first?.image != nil, "Local PNG loads asynchronously into the actual editor preview")
let imageLayout = imageWindow.editor.layoutManager as! LiveLayoutManager
imageLayout.ensureLayout(for: imageWindow.editor.textContainer!)
let afterImage = (imageMarkdown as NSString).range(of: "图片后面的正文")
let afterImageRect = imageLayout.lineFragmentUsedRect(forGlyphAt: imageLayout.glyphIndexForCharacter(at: afterImage.location), effectiveRange: nil)
check(afterImageRect.minY + imageWindow.editor.textContainerOrigin.y >= imageCoordinator.views[0].frame.maxY,
      "Image preview reserves its height and never covers following prose")
check(imageLayout.hiddenCharacters.contains(imageReference.range.location) && imageDoc.source == imageMarkdown,
      "Image preview hides syntax without changing the original Markdown")
check(abs(imageCoordinator.views[0].frame.minX - imageWindow.editor.contentColumn.minX) < 0.1 &&
      imageCoordinator.views[0].frame.width <= imageWindow.editor.contentColumn.width,
      "Images use the body text column and shrink to its width")
imageCoordinator.edit(imageReference)
check(!imageLayout.hiddenCharacters.contains(imageReference.range.location),
      "Clicking an image reveals its editable source while retaining the preview")
imageWindow.editor.insertText("", replacementRange: imageReference.range)
imageWindow.refreshSourcePresentation()
check(imageCoordinator.views.isEmpty, "Deleting an image removes its preview immediately")
imageDoc.undoManager!.undo()
imageWindow.refreshSourcePresentation()
check(imageDoc.source == imageMarkdown && imageCoordinator.views.count == 1,
      "Undo restores the exact image syntax and preview")
check(try! imageDoc.data(ofType: MarkdownDocumentController.typeName) == Data(imageMarkdown.utf8),
      "Loading and rendering images preserve saved document bytes")

let imageVariants = """
![中文](中文.png)
![](folder/a\\(1\\).png "title")
![引用][ Figure ]

[figure]: <folder/中文 空格.png> "title"

\\![不是图片](wrong.png)
\u{0060}![代码](wrong.png)\u{0060}

~~~
![代码块](wrong.png)
~~~

<!-- ![注释](wrong.png) -->
"""
let variants = MarkdownSnapshot(imageVariants, baseURL: directory).images
check(variants.count == 3 && variants[1].destination == "folder/a(1).png" &&
      variants[2].destination == "folder/中文 空格.png",
      "Image parsing respects escapes, references, code and comments")
check(MarkdownSnapshot("![未完成](foo.png\n").images.isEmpty,
      "Unfinished image syntax remains editable source")

let importedDoc = MarkdownDocument()
importedDoc.fileURL = directory.appendingPathComponent("带空格 [图片] #文档.md")
importedDoc.source = "插入前\n\n"
importedDoc.makeWindowControllers()
let importedWindow = importedDoc.windowControllers[0] as! EditorWindowController
importedWindow.editor.setSelectedRange(NSRange(location: importedDoc.source.utf16.count, length: 0))
let board = NSPasteboard.withUniqueName()
defer { board.releaseGlobally() }
board.setData(png, forType: .png)
check(importedWindow.insertImages(from: board), "Screenshot paste enters the document's image import workflow")
let imports = MarkdownSnapshot(importedDoc.source, baseURL: directory).images
check(imports.count == 1 && imports[0].url?.deletingLastPathComponent().lastPathComponent == "带空格 [图片] #文档.assets",
      "Pasted images use a relative path into the document's adjacent asset folder")
check(try! Data(contentsOf: imports[0].url!) == png,
      "Image import preserves original PNG bytes rather than saving its preview thumbnail")
let withImage = importedDoc.source
importedDoc.undoManager!.undo()
settle()
check(importedDoc.source == "插入前\n\n", "Image insertion is one native undo operation")
importedDoc.undoManager!.redo()
settle()
check(importedDoc.source == withImage && FileManager.default.fileExists(atPath: imports[0].url!.path),
      "Redo retains its image asset and restores Markdown")
try importedDoc.write(to: importedDoc.fileURL!, ofType: MarkdownDocumentController.typeName)
let savedImages = MarkdownSnapshot(try String(contentsOf: importedDoc.fileURL!, encoding: .utf8), baseURL: directory).images
check(savedImages.count == 1 && savedImages[0].url == imports[0].url, "Saved image links resolve after reopening")

let missing = directory.appendingPathComponent("missing.png")
let missingStore = ImageStore()
missingStore.request(missing)
for _ in 0..<30 where missingStore.state(for: missing).error == nil { settle() }
check(missingStore.state(for: missing).error != nil, "Missing local images produce a recoverable placeholder")
let invalidURL = directory.appendingPathComponent("invalid.png")
try Data("not an image".utf8).write(to: invalidURL)
do {
    _ = try ImageImport.write([.file(invalidURL)], beside: importedDoc.fileURL!)
    check(false, "Corrupt image rejected")
} catch { check(true, "Corrupt image import fails before editing the document") }

for width: CGFloat in [850, 1300] {
    tableWindow.window?.setContentSize(NSSize(width: width, height: 700))
    tableWindow.window?.contentView?.layoutSubtreeIfNeeded()
    settle()
    tableWindow.refreshSourcePresentation()
    let embedded = tableWindow.editor.subviews.compactMap { $0 as? TableScrollView }.first!
    check(abs(embedded.frame.minX - tableWindow.editor.contentColumn.minX) < 0.1 &&
          abs(embedded.frame.width - tableWindow.editor.contentColumn.width) < 0.1,
          "Table and body text share the same column after resizing to \(Int(width)) points")
}

if let address = ProcessInfo.processInfo.environment["QINGMO_IMAGE_TEST_URL"], let base = URL(string: address) {
    let network = ImageStore()
    let good = base.appendingPathComponent("image.png")
    network.request(good)
    for _ in 0..<40 where network.image(for: good) == nil && network.state(for: good).error == nil { settle() }
    check(network.image(for: good) != nil, "Remote images load through the real URLSession boundary")
    for path in ["missing.png", "invalid.png", "oversize.png"] {
        let url = base.appendingPathComponent(path)
        network.request(url)
        for _ in 0..<40 where network.state(for: url).error == nil { settle() }
        check(network.state(for: url).error != nil, "Remote image failure is recoverable: \(path)")
    }
    let slow = base.appendingPathComponent("slow.png")
    network.request(slow)
    network.retain([])
    for _ in 0..<10 { settle() }
    check(network.image(for: slow) == nil && network.state(for: slow).token == nil,
          "Removed images cancel loading and late responses cannot restore stale previews")
}


print("SUCCESS: \(checks) checks")
