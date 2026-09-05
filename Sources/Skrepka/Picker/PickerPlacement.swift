import AppKit
import Foundation

/// Where the picker appears and how big it gets.
///
/// The top edge is pinned to a fixed fraction of the screen and the panel grows
/// downward from there, so it always opens in the same place no matter how many
/// entries there are — the way Spotlight does.
enum PickerPlacement {
    static let width: CGFloat = 660
    static let maximumHeight: CGFloat = 540
    static let minimumHeight: CGFloat = 150
    /// Distance of the panel's top edge from the top of the visible screen.
    private static let topInsetFraction: CGFloat = 0.18

    static func frame(height: CGFloat) -> NSRect {
        let visible =
            screenUnderPointer()?.visibleFrame ?? NSRect(x: 0, y: 0, width: width, height: maximumHeight)
        let available = min(maximumHeight, visible.height - 40)
        let clamped = height.clamped(to: minimumHeight...max(minimumHeight, available))

        let topY = visible.maxY - visible.height * topInsetFraction
        let originY = max(visible.minY, min(topY - clamped, visible.maxY - clamped))
        return NSRect(
            x: (visible.midX - width / 2).rounded(),
            y: originY.rounded(),
            width: width,
            height: clamped.rounded()
        )
    }

    /// Resizes an existing frame without moving its top edge.
    static func resized(_ frame: NSRect, toHeight height: CGFloat) -> NSRect {
        let visible = screenUnderPointer()?.visibleFrame ?? frame
        let available = min(maximumHeight, visible.height - 40)
        let clamped = height.clamped(to: minimumHeight...max(minimumHeight, available))
        let top = frame.maxY
        return NSRect(
            x: frame.origin.x,
            y: (top - clamped).rounded(),
            width: frame.width,
            height: clamped.rounded()
        )
    }

    private static func screenUnderPointer() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }
}
