import AppKit
import CoreText

/// Only glyph presentation changes. NSTextStorage, selection offsets and undo stay in source coordinates.
final class LiveLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var hiddenCharacters = IndexSet()
    private var replacements: [Int: UniChar] = [:]
    private var tableLineHeights: [Int: CGFloat] = [:]

    func setTableLineHeights(_ heights: [Int: CGFloat]) {
        guard tableLineHeights != heights else { return }
        tableLineHeights = heights
        if let storage = textStorage {
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect usedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>, in container: NSTextContainer,
                       forGlyphRange range: NSRange) -> Bool {
        guard range.length > 0, let height = tableLineHeights[characterIndexForGlyph(at: range.location)] else { return false }
        lineRect.pointee.size.height = height
        usedRect.pointee.size.height = height
        baselineOffset.pointee = min(1, height)
        return true
    }


    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("Programmatic layout only") }

    func present(hidden: IndexSet, replacements: [Int: UniChar]) {
        guard hidden != hiddenCharacters || replacements != self.replacements else { return }
        hiddenCharacters = hidden
        self.replacements = replacements
        if let storage = textStorage, storage.length > 0 {
            invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length),
                             changeInLength: 0, actualCharacterRange: nil)
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes indexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        var properties = Array(UnsafeBufferPointer(start: props, count: range.length))
        var output = Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        var changed = false
        for i in 0..<range.length {
            if hiddenCharacters.contains(indexes[i]) {
                properties[i].insert(.null)
                changed = true
            } else if var character = replacements[indexes[i]] {
                var glyph: CGGlyph = 0
                if CTFontGetGlyphsForCharacters(font as CTFont, &character, &glyph, 1) {
                    output[i] = glyph
                    changed = true
                }
            }
        }
        guard changed else { return 0 }
        output.withUnsafeBufferPointer { newGlyphs in
            properties.withUnsafeBufferPointer { newProperties in
                setGlyphs(newGlyphs.baseAddress!, properties: newProperties.baseAddress!,
                          characterIndexes: indexes, font: font, forGlyphRange: range)
            }
        }
        return range.length
    }
}
