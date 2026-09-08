import Foundation

/// Column padding for the reports.
///
/// Counted in characters rather than in a width-aware measure, which is a
/// limitation worth naming: a preview holding wide CJK glyphs or an emoji
/// pushes its column out. Alignment is cosmetic here and the preview is the
/// last column on the line, so nothing after it is displaced.
extension String {
    func leftPadded(to width: Int, with pad: Character = " ") -> String {
        count >= width ? self : String(repeating: String(pad), count: width - count) + self
    }

    func rightPadded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
