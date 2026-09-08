import Foundation

/// A point in the mark's design box.
///
/// `Double` rather than `CGFloat`, and that is the point of the whole type.
/// swift-corelibs-foundation does vend `CGFloat`, `CGPoint`, `CGRect` and
/// `CGSize` on Linux — but not `CGPath`, `CGMutablePath` or
/// `CGAffineTransform`, and not the `CoreGraphics` module that declares them
/// (OQ-12, verified by compiling each case in a container). So the geometry
/// value types port and the drawing types do not, and this sits on that split.
public struct MarkPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A circular arc, as the segment that carries one names it.
///
/// A value type rather than five associated values on ``MarkSegment/arc``,
/// because five is past the point where a call site reads: `.arc(a, b, c, d, e)`
/// says nothing about which of the two angles is the start, and swapping them
/// draws the complement of the arc you meant. Named fields make that a
/// compile error rather than a redrawn logo.
public struct MarkArc: Equatable, Sendable {
    public let center: MarkPoint
    public let radius: Double
    /// Radians, measured the way both renderers measure them: from the positive
    /// x-axis, increasing towards positive y.
    public let startAngle: Double
    public let endAngle: Double
    public let clockwise: Bool

    public init(
        center: MarkPoint, radius: Double, startAngle: Double, endAngle: Double, clockwise: Bool
    ) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.clockwise = clockwise
    }
}

/// One command in a mark's outline.
///
/// The four an artwork actually needs, and no more. A richer IR would be a
/// second drawing model to keep in step with two renderers; this one is small
/// enough to read against the SVG it was transcribed from.
public enum MarkSegment: Equatable, Sendable {
    case move(to: MarkPoint)
    case line(to: MarkPoint)
    case curve(control1: MarkPoint, control2: MarkPoint, to: MarkPoint)
    /// A circular arc, kept as an arc rather than flattened into cubics.
    ///
    /// Flattening at construction time would make the IR lossy for the sake of
    /// one fewer case, and the end caps are exactly where a rounding difference
    /// between two renderers would show. The intended destinations can draw arcs
    /// natively — `CGMutablePath.addArc` and, in a future Linux renderer,
    /// `cairo_arc` — so nothing is gained by approximating one here.
    case arc(MarkArc)
    case close
}

/// A closed outline in a mark's own coordinates, with no opinion about how it
/// is drawn.
///
/// The type OQ-12 asked for. `PaperclipPath` renders one to `CGPath` on Apple
/// platforms; a future Cairo renderer can draw the same value on Linux. The
/// coordinate table lives here, once, so the icon, the menu bar and the tray
/// cannot drift apart across two platforms as well as across three surfaces.
/// Its ``boundingBox`` lives in `MarkPath+Bounds.swift`, which is where the
/// curve arithmetic that keeps it in step with `CGPath.boundingBoxOfPath` is.
public struct MarkPath: Equatable, Sendable {
    public let segments: [MarkSegment]

    public init(segments: [MarkSegment]) {
        self.segments = segments
    }
}

// MARK: - Building

extension MarkPath {
    /// Collects segments in the order they are stated, so a coordinate table
    /// reads as one line per segment.
    public struct Builder {
        private var segments: [MarkSegment] = []
        private var currentPoint = MarkPoint(0, 0)

        public init() {}

        public mutating func move(to end: (Double, Double)) {
            currentPoint = MarkPoint(end.0, end.1)
            segments.append(.move(to: currentPoint))
        }

        public mutating func line(to end: (Double, Double)) {
            currentPoint = MarkPoint(end.0, end.1)
            segments.append(.line(to: currentPoint))
        }

        public mutating func curve(
            _ control1: (Double, Double),
            _ control2: (Double, Double),
            to end: (Double, Double)
        ) {
            currentPoint = MarkPoint(end.0, end.1)
            segments.append(
                .curve(
                    control1: MarkPoint(control1.0, control1.1),
                    control2: MarkPoint(control2.0, control2.1),
                    to: currentPoint
                ))
        }

        /// Rounds off a free end: a half turn from where the wire's edge
        /// stopped, landing on the far edge at `end`. The source art cuts both
        /// ends square, which reads as a snapped-off stub rather than as wire.
        ///
        /// Clockwise in design-box numbers — the design box has a top-left
        /// origin, so this bulges away from the body of the clip at both ends.
        public mutating func roundCap(to end: (Double, Double)) {
            let start = currentPoint
            let finish = MarkPoint(end.0, end.1)
            let center = MarkPoint((start.x + finish.x) / 2, (start.y + finish.y) / 2)
            segments.append(
                .arc(
                    MarkArc(
                        center: center,
                        radius: hypot(finish.x - start.x, finish.y - start.y) / 2,
                        startAngle: atan2(start.y - center.y, start.x - center.x),
                        endAngle: atan2(finish.y - center.y, finish.x - center.x),
                        clockwise: true
                    )))
            currentPoint = finish
        }

        public mutating func close() {
            segments.append(.close)
        }

        public func build() -> MarkPath {
            MarkPath(segments: segments)
        }
    }
}
