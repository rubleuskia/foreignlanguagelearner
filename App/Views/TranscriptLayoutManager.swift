import UIKit

/// Paint-only decorations. Never mutate NSTextStorage while scrolling: UIKit treats those edits
/// as text changes and may reveal the insertion point or restart layout/following.
final class TranscriptLayoutManager: NSLayoutManager {
    private(set) var unknownRanges: [NSRange] = []
    private(set) var activeRange: NSRange?
    private var underlineWords = false
    private var glyphTint: UIColor?
    private let wordColor = UIColor { $0.userInterfaceStyle == .dark ? .systemYellow : .systemBrown }

    func setWords(_ ranges: [NSRange], underline: Bool) {
        guard ranges != unknownRanges || underline != underlineWords else { return }
        for range in unknownRanges { invalidateDisplay(forCharacterRange: range) }
        unknownRanges = ranges; underlineWords = underline
        for range in ranges { invalidateDisplay(forCharacterRange: range) }
    }

    func setActiveRange(_ range: NSRange?) {
        guard range != activeRange else { return }
        if let activeRange { invalidateDisplay(forCharacterRange: activeRange) }
        activeRange = range
        if let range { invalidateDisplay(forCharacterRange: range) }
    }

    func clearDecorations() {
        setWords([], underline: false)
        setActiveRange(nil)
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        if let activeRange, let container = textContainers.first, let context = UIGraphicsGetCurrentContext() {
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: activeRange, actualCharacterRange: nil), glyphsToShow)
            if glyphs.length > 0 {
                context.saveGState()
                UIColor.systemYellow.withAlphaComponent(0.25).setFill()
                enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                    context.fill(rect.offsetBy(dx: origin.x, dy: origin.y))
                }
                context.restoreGState()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for range in unknownRanges {
            let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphsToShow)
            let start = max(cursor, glyphs.location)
            guard glyphs.length > 0, NSMaxRange(glyphs) > start else { continue }
            if start > cursor { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: start - cursor), at: origin) }
            let tinted = NSRange(location: start, length: NSMaxRange(glyphs) - start)
            glyphTint = wordColor
            super.drawGlyphs(forGlyphRange: tinted, at: origin)
            glyphTint = nil
            if underlineWords, let context = UIGraphicsGetCurrentContext() {
                context.saveGState(); wordColor.setFill(); wordColor.setStroke()
                enumerateLineFragments(forGlyphRange: tinted) { rect, _, _, lineRange, _ in
                    self.underlineGlyphRange(NSIntersectionRange(tinted, lineRange), underlineType: .single,
                                             lineFragmentRect: rect, lineFragmentGlyphRange: lineRange, containerOrigin: origin)
                }
                context.restoreGState()
            }
            cursor = NSMaxRange(tinted)
        }
        if cursor < end { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor), at: origin) }
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int,
                               font: UIFont, textMatrix: CGAffineTransform,
                               attributes: [NSAttributedString.Key: Any], in context: CGContext) {
        guard let glyphTint else {
            super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix, attributes: attributes, in: context)
            return
        }
        context.saveGState()
        context.setFillColor(glyphTint.cgColor)
        var tinted = attributes; tinted[.foregroundColor] = glyphTint
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix, attributes: tinted, in: context)
        context.restoreGState()
    }
}
