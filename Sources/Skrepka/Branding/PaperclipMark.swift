import SkrepkaCore
import SwiftUI

/// The Skrepka paperclip, for the app's own surfaces.
///
/// A shape rather than an `Image(systemName:)`: every window that introduces the
/// app was borrowing a system clipboard symbol, which is a picture of what the
/// app does and not of the app. This is the same path the menu bar mark and
/// `AppIcon.icns` are drawn from, so the three cannot drift.
///
/// SwiftUI hands a shape a top-left origin, which is the design box's own, so
/// the path needs no flip.
struct PaperclipMark: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        guard let mark = PaperclipPath.fitted(in: rect, flipped: false) else { return Path() }
        return Path(mark)
    }
}
