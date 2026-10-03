import Testing

@testable import SkrepkaLinuxUI

/// The footer's arrow, return and shift caps are drawn, so where their ink
/// sits is the drawing's to get right rather than a fallback font's.
@Suite("Key glyphs")
struct KeyGlyphTests {
    @Test("the footer's symbols are drawn; letters and words stay text")
    func symbols() {
        #expect(KeyGlyph(symbol: "↑") == .up)
        #expect(KeyGlyph(symbol: "↓") == .down)
        #expect(KeyGlyph(symbol: "↩") == .enter)
        #expect(KeyGlyph(symbol: "⇧") == .shift)
        #expect(KeyGlyph(symbol: "P") == nil)
        #expect(KeyGlyph(symbol: "Alt") == nil)
        #expect(KeyGlyph(symbol: "Esc") == nil)
    }

    /// The bug this type exists for: a typed `↩` sat high in its cap. Centred
    /// ink is what puts a glyph in the middle of a centred square.
    @Test("every glyph's ink is centred in its square", arguments: KeyGlyph.allCases)
    func centred(glyph: KeyGlyph) {
        let points = glyph.strokes.flatMap(\.points)
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let tolerance = 0.000_001
        #expect(abs(((xs.min() ?? 0) + (xs.max() ?? 0)) / 2 - 0.5) < tolerance)
        #expect(abs(((ys.min() ?? 0) + (ys.max() ?? 0)) / 2 - 0.5) < tolerance)
    }

    /// Inside the unit square, and touching two opposite edges: a glyph drawn
    /// smaller than the rest would read as a different weight of key.
    @Test("every glyph fills its square on at least one axis", arguments: KeyGlyph.allCases)
    func fills(glyph: KeyGlyph) {
        let points = glyph.strokes.flatMap(\.points)
        #expect(points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        let width = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let height = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        #expect(max(width, height) == 1)
    }

    @Test("every drawn cap has words for a screen reader")
    func spoken() {
        #expect(KeyGlyph.allCases.allSatisfy { !$0.spokenName.isEmpty })
        #expect(Set(KeyGlyph.allCases.map(\.spokenName)).count == KeyGlyph.allCases.count)
    }
}
