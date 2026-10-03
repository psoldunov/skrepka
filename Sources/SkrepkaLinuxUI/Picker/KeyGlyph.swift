import CGtk4

/// A key the picker's footer draws rather than types — the two arrows, return
/// and shift.
///
/// Typed, `↑` `↓` `↩` `⇧` landed wherever the font that had them put them. An
/// interface font need not carry them, so they could come from a fallback font
/// with its own ascent and descent, and GTK centres a label's *line*, not its
/// ink: on KDE the glyphs sat high and off to one side in their caps. The Mac
/// draws these keys as SF Symbols, which are drawings too. Drawn here, each
/// glyph's ink is centred in its square by construction — ``strokes`` holds
/// that as an invariant the tests check.
enum KeyGlyph: CaseIterable {
    case up
    case down
    case enter
    case shift

    /// A point in the glyph's unit square, y down.
    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    /// One pen stroke: a polyline, closed into an outline or left open.
    struct Stroke: Equatable {
        let points: [Point]
        let isClosed: Bool
    }

    /// The glyph `symbol` is drawn as, or nil for a key that is a word.
    init?(symbol: String) {
        switch symbol {
        case "↑": self = .up
        case "↓": self = .down
        case "↩": self = .enter
        case "⇧": self = .shift
        default: return nil
        }
    }

    /// What a screen reader says for the cap, which has no text of its own.
    var spokenName: String {
        switch self {
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .enter: "Enter"
        case .shift: "Shift"
        }
    }

    /// The pen strokes, in the unit square. Every glyph's ink spans the square
    /// edge to edge on at least one axis and is centred on both.
    var strokes: [Stroke] {
        switch self {
        case .up:
            Self.arrow(pointingDown: false)
        case .down:
            Self.arrow(pointingDown: true)
        case .enter:
            // Down the right-hand side, then left into the arrowhead — the
            // Mac's `return` symbol. The head is a right angle, like the
            // arrows'.
            [
                Stroke(points: [Self.p(0.9, 0), Self.p(0.9, 0.64), Self.p(0.1, 0.64)], isClosed: false),
                Stroke(points: [Self.p(0.46, 0.28), Self.p(0.1, 0.64), Self.p(0.46, 1)], isClosed: false),
            ]
        case .shift:
            // The outlined arrow on the key itself.
            [
                Stroke(
                    points: [
                        Self.p(0.5, 0), Self.p(1, 0.5), Self.p(0.74, 0.5), Self.p(0.74, 1),
                        Self.p(0.26, 1), Self.p(0.26, 0.5), Self.p(0, 0.5),
                    ],
                    isClosed: true
                )
            ]
        }
    }

    private static func arrow(pointingDown: Bool) -> [Stroke] {
        let tip = pointingDown ? 1.0 : 0.0
        let tail = 1 - tip
        let barb = pointingDown ? 0.65 : 0.35
        return [
            Stroke(points: [p(0.5, tail), p(0.5, tip)], isClosed: false),
            Stroke(points: [p(0.15, barb), p(0.5, tip), p(0.85, barb)], isClosed: false),
        ]
    }

    private static func p(_ x: Double, _ y: Double) -> Point {
        Point(x: x, y: y)
    }

    // MARK: - Drawing

    /// The pen's width as a share of the glyph's side: about the stem of the
    /// caps' 600-weight lettering, so `↩` and `Alt` side by side read as one
    /// weight.
    static let penShare = 0.15

    /// Strokes the glyph in `color`, centred in a `width` × `height` area as
    /// the largest square that keeps the pen inside it.
    func draw(_ cairo: OpaquePointer, width: Int32, height: Int32, color: GdkRGBA) {
        let area = Double(min(width, height))
        guard area > 0 else { return }
        let pen = max(1, area * Self.penShare)
        let side = area - pen
        let originX = (Double(width) - side) / 2
        let originY = (Double(height) - side) / 2

        cairo_set_line_width(cairo, pen)
        cairo_set_line_cap(cairo, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cairo, CAIRO_LINE_JOIN_ROUND)
        cairo_set_source_rgba(
            cairo, Double(color.red), Double(color.green), Double(color.blue), Double(color.alpha))
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            cairo_move_to(cairo, originX + first.x * side, originY + first.y * side)
            for point in stroke.points.dropFirst() {
                cairo_line_to(cairo, originX + point.x * side, originY + point.y * side)
            }
            if stroke.isClosed { cairo_close_path(cairo) }
            cairo_stroke(cairo)
        }
    }
}
