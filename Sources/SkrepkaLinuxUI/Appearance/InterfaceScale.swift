import Foundation

/// How much larger than its design size the app draws its picker and its
/// Settings window — the General pane's "Interface size".
///
/// On top of the desktop's own scaling, not instead of it: the compositor
/// still scales the whole surface for the output, and this makes what is drawn
/// on that surface larger. The picker was drawn at the Mac's sizes — 13-pixel
/// titles, a 660-pixel panel — and on a desktop whose own apps run larger, that
/// reads as small whatever the output's scale.
///
/// Every length the app states scales by it: the stylesheets' through
/// ``stylesheet(_:)``, the sizes code gives a widget through ``length(_:)``, and
/// the gaps between a box's children through ``gapStylesheet(scope:)``. So the
/// interface grows as one drawing rather than as larger text in the same
/// boxes.
public struct InterfaceScale: Sendable, Hashable {
    /// The size as a percentage of the design size.
    public let percent: Int

    /// The design size.
    public static let standard = InterfaceScale(validPercent: 100)

    /// The sizes the General pane offers, smallest first.
    public static let choices = [100, 110, 125, 150, 175, 200]

    /// The sizes accepted from the settings file. Nothing smaller than the
    /// design size — the picker's 10- and 11-pixel hints are already as small
    /// as text should get — and nothing past twice it, where the picker is
    /// already wider than a Steam Deck's screen.
    public static let accepted = 100...200

    /// Nil for a percentage outside ``accepted``.
    public init?(percent: Int) {
        guard Self.accepted.contains(percent) else { return nil }
        self.percent = percent
    }

    private init(validPercent: Int) {
        percent = validPercent
    }

    /// `base` pixels at this size, to the nearest whole pixel.
    ///
    /// A length of one pixel or less is a hairline — a separator, a card's
    /// border, an inset edge — and stays as it is: grown to a pixel and a
    /// quarter it would straddle two rows of pixels and blur, where the point
    /// of a hairline is to be the thinnest line the screen draws.
    public func length(_ base: Int32) -> Int32 {
        Int32(scaled(Double(base)))
    }

    /// `base` pixels at this size — ``length(_:)`` for a fractional length.
    func scaled(_ base: Double) -> Double {
        guard abs(base) > 1 else { return base }
        return (base * Double(percent) / 100).rounded()
    }
}

// MARK: - Stylesheets

extension InterfaceScale {
    /// `css` with every pixel length in it scaled by ``scaled(_:)``.
    ///
    /// The stylesheets are generated in code and state every length in `px`,
    /// so rewriting the lengths is the whole of scaling them — GTK 4.12, the
    /// Linux floor, has no CSS custom properties to multiply by instead.
    /// Nothing but a length ends in `px`: colours are `rgba()` and `#rrggbb`,
    /// opacities and font weights are bare numbers, and no class name ends in
    /// one.
    public func stylesheet(_ css: String) -> String {
        guard self != .standard else { return css }
        return css.replacing(Self.pixelLength) { match in
            "\(Self.format(scaled(Double(match.output.1) ?? 0)))px"
        }
    }

    /// The tail of a stylesheet that grows every gap a box built by `Build.box`
    /// or `GtkBuild.box` keeps between its children, under the window class
    /// `scope`.
    ///
    /// A box's gap is its own spacing *plus* the CSS `border-spacing` it is
    /// styled with — `GtkBoxLayout` adds the two (`get_spacing` in
    /// gtkboxlayout.c, GTK 4.12). So a box built with an 11-pixel gap wears
    /// ``gapClass(_:)``'s class for 11, and this adds the difference between 11
    /// and 11 at this size. The gap grows the moment the stylesheet is
    /// installed, with no box rebuilt; at the design size there is no
    /// difference and no rule.
    public func gapStylesheet(scope: String) -> String {
        Self.scaledGaps.compactMap { gap -> String? in
            let growth = length(gap) - gap
            guard growth > 0 else { return nil }
            return "\(scope) .\(Self.gapClassName(gap)) { border-spacing: \(growth)px; }"
        }
        .joined(separator: "\n")
    }

    /// The class a box whose children are `spacing` pixels apart wears, so the
    /// gap grows with the interface — nil for no gap, and for one wider than
    /// any the app draws.
    static func gapClass(_ spacing: Int32) -> String? {
        scaledGaps.contains(spacing) ? gapClassName(spacing) : nil
    }

    /// Every gap a box may be built with and still grow. The widest the app
    /// uses is 18, between a Settings page's cards.
    static let scaledGaps: ClosedRange<Int32> = 1...32

    private static func gapClassName(_ spacing: Int32) -> String {
        "skrepka-gap-\(spacing)"
    }

    /// A number followed by `px`: `13px`, `0.5px`, `.5px`, `-1px`. Built per
    /// call rather than stored: a stylesheet is rewritten once per restyle, and
    /// a stored `Regex` would have to be shared across isolation domains.
    private static var pixelLength: Regex<(Substring, Substring)> {
        /(-?\d*\.?\d+)px/
    }

    /// `14`, not `14.0` — GTK reads either, but the stylesheet stays legible.
    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
