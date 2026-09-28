import SkrepkaCore

/// The palette's sizes at an interface size, and the arithmetic that fits it on
/// the screen it is opening on.
///
/// The design sizes are the macOS picker's, from
/// `Sources/Skrepka/Picker/PickerPlacement.swift` and `PickerMetrics.swift`,
/// because the two platforms should be the same product rather than two
/// designs; ``standard`` is exactly those. Every other ``InterfaceScale`` grows
/// them together, so the panel's height stays the sum of the rows its
/// stylesheet draws. What is *not* shared is the clamp: the Mac clamps against
/// a laptop display, and the Linux test rig is a Steam Deck at **1280×800**,
/// where the Mac's 540-point maximum is two thirds of the screen height.
/// `height(rows:outputHeight:)` is the whole reason this type exists rather
/// than a handful of constants.
///
/// Pure arithmetic on purpose. Nothing here touches GTK, so the fit can be
/// tested at every screen size that matters without a display.
public struct PaletteMetrics: Sendable, Equatable {
    public let scale: InterfaceScale

    public init(scale: InterfaceScale) {
        self.scale = scale
    }

    /// The Mac's sizes.
    public static let standard = PaletteMetrics(scale: .standard)

    /// Matches `PickerPlacement.width` on macOS.
    public var width: Int32 { scale.length(660) }
    /// Matches `PickerPlacement.maximumHeight`.
    public var maximumHeight: Int32 { scale.length(540) }
    /// Matches `PickerPlacement.minimumHeight`.
    public var minimumHeight: Int32 { scale.length(150) }
    /// Matches `PickerMetrics.rowSpacing` doubled — GTK's box spacing is the
    /// gap between children, where SwiftUI's padding is around them.
    public var gutter: Int32 { scale.length(4) }
    /// Matches `PickerMetrics.standardRowHeight`.
    public var standardRowHeight: Int32 { scale.length(46) }
    /// Matches `PickerMetrics.imageRowHeight`.
    public var imageRowHeight: Int32 { scale.length(64) }
    /// The search row's height.
    public var searchHeight: Int32 { scale.length(50) }
    /// The footer's height.
    public var footerHeight: Int32 { scale.length(34) }
    /// `searchHeight` + `footerHeight` + two separators, which are hairlines at
    /// every size.
    public var chromeHeight: Int32 { searchHeight + footerHeight + 2 }
    /// Matches `PickerMetrics.emptyStateHeight`.
    var emptyStateHeight: Int32 { scale.length(150) }

    /// The 30pt kind tile the macOS row leads with.
    var tileSide: Int32 { scale.length(30) }
    /// The macOS row's 84×48 image preview.
    var previewSize: (width: Int32, height: Int32) { (scale.length(84), scale.length(48)) }

    /// The largest share of the screen's height the palette may take.
    ///
    /// Two thirds, which on the Deck's 800-pixel panel is 533 — a hair under
    /// the Mac's 540 maximum, so on that machine the two agree and on anything
    /// smaller the screen wins. On a 1080p desktop the Mac's maximum binds
    /// first, which is the intended order: the cap exists to stop a small
    /// screen being swallowed, not to grow the palette on a large one. A
    /// larger interface size raises the maximum, and the screen binds sooner.
    public static let maximumScreenFraction = 2.0 / 3.0

    /// The height the palette wants for `rows`, fitted to a screen
    /// `outputHeight` pixels tall.
    ///
    /// - Parameter outputHeight: the active output's height in pixels, or 0
    ///   when it is not known yet — in which case only the fixed maximum
    ///   applies, which is the same answer the Mac gives.
    public func height(rows: [ClipSummary], outputHeight: Int32) -> Int32 {
        let wanted = wantedHeight(rowHeights: rows.map(rowHeight(for:)))
        return min(max(wanted, minimumHeight), ceiling(outputHeight: outputHeight))
    }

    /// The height the panel wants for rows `rowHeights` tall, before any
    /// screen — the chrome and the empty state when there are none.
    func wantedHeight(rowHeights: [Int32]) -> Int32 {
        guard !rowHeights.isEmpty else { return chromeHeight + emptyStateHeight }
        let spacing = gutter * Int32(rowHeights.count - 1)
        return chromeHeight + rowHeights.reduce(0, +) + spacing
    }

    /// The tallest the palette may be on this screen.
    public func ceiling(outputHeight: Int32) -> Int32 {
        guard outputHeight > 0 else { return maximumHeight }
        let share = Int32((Double(outputHeight) * Self.maximumScreenFraction).rounded(.down))
        // `minimumHeight` wins over the share on a screen small enough for the
        // two to cross, because a palette shorter than its own chrome is not a
        // smaller palette, it is a broken one.
        return max(minimumHeight, min(maximumHeight, share))
    }

    /// How far down the output the panel's top edge hangs, in percent of the
    /// output's height — `PickerPlacement.topInsetFraction` on macOS, as an
    /// integer so the Deck's 800 pixels give exactly 144 rather than whatever
    /// `0.18` rounds to in binary.
    public static let topInsetPercent: Int32 = 18

    /// Where a panel that wants `wantedHeight` goes on an output
    /// `outputWidth` × `outputHeight`, both in logical pixels.
    ///
    /// The macOS placement: centred across, and hung from a fixed top edge
    /// rather than centred down. A query that narrows the list shortens the
    /// panel from the bottom, so the search field — at the top — never moves
    /// under the caret. The top rises only where even the tallest panel this
    /// output allows would otherwise run off the bottom.
    ///
    /// - Parameters:
    ///   - outputWidth: 0 when the output is not known yet, like
    ///     `outputHeight` in ``ceiling(outputHeight:)``.
    public func frame(wantedHeight: Int32, outputWidth: Int32, outputHeight: Int32) -> PaletteFrame {
        let tallest = ceiling(outputHeight: outputHeight)
        let preferredTop = outputHeight * Self.topInsetPercent / 100
        let top = max(0, min(preferredTop, outputHeight - tallest))
        let panelWidth = outputWidth > 0 ? min(width, outputWidth) : width
        return PaletteFrame(
            x: max(0, (outputWidth - panelWidth) / 2),
            y: top,
            width: panelWidth,
            height: min(max(wantedHeight, minimumHeight), tallest)
        )
    }

    /// `frame`, grown to the smallest size the panel can be drawn at and kept on
    /// the output.
    ///
    /// GTK warns about, and clips, a widget given less than it measured, which
    /// a narrow or portrait output can do to the fixed width and a short one to
    /// the height cap. A panel that has to grow past the cap moves up rather
    /// than off the bottom.
    public static func fit(
        _ frame: PaletteFrame,
        minimumWidth: Int32,
        minimumHeight: Int32,
        outputWidth: Int32,
        outputHeight: Int32
    ) -> PaletteFrame {
        let width = max(frame.width, minimumWidth)
        let height = max(frame.height, minimumHeight)
        return PaletteFrame(
            x: outputWidth > width ? (outputWidth - width) / 2 : 0,
            y: outputHeight > 0 ? max(0, min(frame.y, outputHeight - height)) : frame.y,
            width: width,
            height: height
        )
    }

    /// Matches `PickerMetrics.rowHeight(for:)`.
    func rowHeight(for item: ClipSummary) -> Int32 {
        guard !item.isConcealed else { return standardRowHeight }
        return rowHeight(isImage: item.hasThumbnail || item.hasStackIcons)
    }

    /// A row with a picture preview, or one with a kind tile.
    func rowHeight(isImage: Bool) -> Int32 {
        isImage ? imageRowHeight : standardRowHeight
    }
}
