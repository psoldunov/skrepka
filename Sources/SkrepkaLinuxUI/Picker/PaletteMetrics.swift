import SkrepkaCore

/// Fixed sizes for the palette, and the arithmetic that fits it on the screen
/// it is opening on.
///
/// The numbers are the macOS picker's, from `Sources/Skrepka/Picker/PickerPlacement.swift`
/// and `PickerMetrics.swift`, because the two platforms should be the same
/// product rather than two designs. What is *not* shared is the clamp: the Mac
/// clamps against a laptop display, and the Linux test rig is a Steam Deck at
/// **1280×800**, where the Mac's 540-point maximum is two thirds of the screen
/// height. `height(rows:outputHeight:)` is the whole reason this type exists
/// rather than four constants.
///
/// Pure arithmetic on purpose. Nothing here touches GTK, so the fit can be
/// tested at every screen size that matters without a display.
public enum PaletteMetrics {
    /// Matches `PickerPlacement.width` on macOS.
    public static let width: Int32 = 660
    /// Matches `PickerPlacement.maximumHeight`.
    public static let maximumHeight: Int32 = 540
    /// Matches `PickerPlacement.minimumHeight`.
    public static let minimumHeight: Int32 = 150
    /// Matches `PickerMetrics.rowSpacing` doubled — GTK's box spacing is the
    /// gap between children, where SwiftUI's padding is around them.
    public static let gutter: Int32 = 4
    /// Matches `PickerMetrics.standardRowHeight`.
    public static let standardRowHeight: Int32 = 46
    /// Matches `PickerMetrics.imageRowHeight`.
    public static let imageRowHeight: Int32 = 64
    /// `searchFieldHeight` + `footerHeight` + two separators.
    public static let chromeHeight: Int32 = 50 + 34 + 2

    /// The largest share of the screen's height the palette may take.
    ///
    /// Two thirds, which on the Deck's 800-pixel panel is 533 — a hair under
    /// the Mac's 540 maximum, so on that machine the two agree and on anything
    /// smaller the screen wins. On a 1080p desktop the Mac's maximum binds
    /// first, which is the intended order: the cap exists to stop a small
    /// screen being swallowed, not to grow the palette on a large one.
    public static let maximumScreenFraction = 2.0 / 3.0

    /// The height the palette wants for `rows`, fitted to a screen
    /// `outputHeight` pixels tall.
    ///
    /// - Parameter outputHeight: the active output's height in pixels, or 0
    ///   when it is not known yet — in which case only the fixed maximum
    ///   applies, which is the same answer the Mac gives.
    public static func height(rows: [ClipSummary], outputHeight: Int32) -> Int32 {
        let content = rows.reduce(Int32(0)) { $0 + self.rowHeight(for: $1) }
        let spacing = gutter * Int32(max(0, rows.count - 1))
        let wanted = rows.isEmpty ? chromeHeight + emptyStateHeight : chromeHeight + content + spacing
        return min(max(wanted, minimumHeight), ceiling(outputHeight: outputHeight))
    }

    /// The tallest the palette may be on this screen.
    public static func ceiling(outputHeight: Int32) -> Int32 {
        guard outputHeight > 0 else { return maximumHeight }
        let share = Int32((Double(outputHeight) * maximumScreenFraction).rounded(.down))
        // `minimumHeight` wins over the share on a screen small enough for the
        // two to cross, because a palette shorter than its own chrome is not a
        // smaller palette, it is a broken one.
        return max(minimumHeight, min(maximumHeight, share))
    }

    /// Matches `PickerMetrics.rowHeight(for:)`.
    static func rowHeight(for item: ClipSummary) -> Int32 {
        guard !item.isConcealed else { return standardRowHeight }
        return item.hasThumbnail || item.hasStackIcons ? imageRowHeight : standardRowHeight
    }

    /// Matches `PickerMetrics.emptyStateHeight`.
    private static let emptyStateHeight: Int32 = 150
}
