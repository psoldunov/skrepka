import Foundation

// The tight bounding box of a ``MarkPath``, and the curve arithmetic it needs.
//
// Split out of `MarkPath.swift` because it is the one part of the IR that is
// arithmetic rather than description: the type itself is a list of segments and
// reads as one, while this is two root solvers and a sweep test.
//
// It exists to agree with `CGPath.boundingBoxOfPath` to the last decimal that
// matters, because the two renderers fit the mark by dividing a destination
// rectangle by this box. A box that is looser here than there does not draw a
// looser mark — it draws a *smaller* one, offset, and only on one platform.
// That is the drift ``MarkPath`` was introduced to make impossible, so the
// agreement is pinned by a test rather than left to this comment.

extension MarkPath {

    /// The smallest box containing the curve itself.
    ///
    /// Tight, not the control hull: a cubic's control points usually sit
    /// outside the curve they steer, and an arc sweeps only part of its circle.
    /// Both are excluded, which is what makes this the same box
    /// `CGPath.boundingBoxOfPath` returns — documented as "the smallest
    /// rectangle completely enclosing all points in the path, *not* including
    /// control points". (`CGPathGetBoundingBox` is the one that includes them,
    /// and is not what either renderer fits against.)
    ///
    /// Arcs are the one place the two cannot be identical: Core Graphics
    /// flattens an arc into cubics before measuring it, and the standard
    /// quarter-circle approximation falls inside the true circle by about
    /// 2.7e-4 of the radius. On this mark's 57.9-unit end caps that is 0.016
    /// units, which is why the test that pins the agreement uses a tolerance
    /// rather than equality.
    ///
    /// - Returns: `nil` for a path that states no point at all.
    public var boundingBox: (origin: MarkPoint, width: Double, height: Double)? {
        var box = Bounds()
        var current: MarkPoint?
        var subpathStart: MarkPoint?

        for segment in segments {
            switch segment {
            case .move(let point):
                box.include(point)
                current = point
                subpathStart = point
            case .line(let point):
                box.include(point)
                current = point
            case .curve(let control1, let control2, let end):
                // Core Graphics ignores a curve with no current point, so a
                // path that opens with one contributes its end alone here too.
                if let start = current {
                    box.include(start)
                    box.include(Self.cubicExtrema(from: start, control1, control2, to: end))
                }
                box.include(end)
                current = end
            case .arc(let arc):
                box.include(Self.arcExtrema(arc))
                current = arc.point(at: arc.endAngle)
            case .close:
                current = subpathStart
            }
        }

        return box.result
    }

    // MARK: - Cubics

    /// The points where a cubic turns back on itself, in either axis.
    ///
    /// A cubic's extremes are its two endpoints plus wherever its derivative
    /// crosses zero. The caller already has the endpoints, so only the turning
    /// points come back from here.
    static func cubicExtrema(
        from start: MarkPoint,
        _ control1: MarkPoint,
        _ control2: MarkPoint,
        to end: MarkPoint
    ) -> [MarkPoint] {
        let turns =
            derivativeRoots(start.x, control1.x, control2.x, end.x)
            + derivativeRoots(start.y, control1.y, control2.y, end.y)
        return turns.map { point(onCubic: start, control1, control2, end, at: $0) }
    }

    /// Where `B'(t) == 0` for one axis, keeping only roots strictly inside the
    /// segment — a root at 0 or 1 is an endpoint the caller already has.
    ///
    /// `B'(t)/3` is the quadratic `at² + bt + c` for `a = -p0 + 3p1 - 3p2 + p3`,
    /// `b = 2(p0 - 2p1 + p2)`, `c = p1 - p0`.
    private static func derivativeRoots(
        _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double
    ) -> [Double] {
        let squared = -p0 + 3 * p1 - 3 * p2 + p3
        let linear = 2 * (p0 - 2 * p1 + p2)
        let constant = p1 - p0

        // Not a tolerance to tune: a zero square term makes the quadratic
        // linear, and dividing by it would produce an infinite root rather
        // than no root.
        guard abs(squared) > .ulpOfOne else {
            guard abs(linear) > .ulpOfOne else { return [] }
            return [-constant / linear].filter(isInsideSegment)
        }

        let discriminant = linear * linear - 4 * squared * constant
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        return [(-linear + root) / (2 * squared), (-linear - root) / (2 * squared)]
            .filter(isInsideSegment)
    }

    private static func isInsideSegment(_ position: Double) -> Bool {
        position > 0 && position < 1
    }

    private static func point(
        onCubic start: MarkPoint,
        _ control1: MarkPoint,
        _ control2: MarkPoint,
        _ end: MarkPoint,
        at position: Double
    ) -> MarkPoint {
        let remaining = 1 - position
        func value(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            let start = remaining * remaining * remaining * p0
            let lead = 3 * remaining * remaining * position * p1
            let trail = 3 * remaining * position * position * p2
            return start + lead + trail + position * position * position * p3
        }
        return MarkPoint(
            value(start.x, control1.x, control2.x, end.x),
            value(start.y, control1.y, control2.y, end.y)
        )
    }

    // MARK: - Arcs

    /// An arc's two ends, plus whichever of the circle's four axis extremes the
    /// sweep actually reaches.
    ///
    /// The sweep test is the whole point. A half-turn end cap touches two of
    /// the four; taking all four would put the box on the full circle and give
    /// back the over-estimate this file exists to avoid.
    static func arcExtrema(_ arc: MarkArc) -> [MarkPoint] {
        var points = [arc.point(at: arc.startAngle), arc.point(at: arc.endAngle)]
        for quadrant in 0..<4 {
            let angle = Double(quadrant) * .pi / 2
            if arc.sweepReaches(angle) { points.append(arc.point(at: angle)) }
        }
        return points
    }
}

// MARK: - Arc geometry

extension MarkArc {
    /// The point on the circle at `angle`, in the same convention
    /// ``MarkArc/startAngle`` is measured in.
    func point(at angle: Double) -> MarkPoint {
        MarkPoint(center.x + radius * cos(angle), center.y + radius * sin(angle))
    }

    /// How far the arc turns, as a magnitude in `[0, 2π]`.
    ///
    /// Zero only when the two angles are literally equal. A full turn — the
    /// same angle reached by adding 2π — has to come back as 2π rather than
    /// wrap to zero, or a circle would be measured as the single point it
    /// starts from. That is also what `CGMutablePath.addArc` does with the two
    /// cases: `(0, 2π)` draws a circle and `(0, 0)` draws nothing.
    var sweep: Double {
        let turned = clockwise ? startAngle - endAngle : endAngle - startAngle
        guard turned != 0 else { return 0 }
        let wrapped = Self.wrapped(turned)
        return wrapped == 0 ? 2 * .pi : wrapped
    }

    /// Whether travelling from ``startAngle`` in this arc's direction passes
    /// through `angle` before reaching ``endAngle``.
    func sweepReaches(_ angle: Double) -> Bool {
        let travelled = Self.wrapped(clockwise ? startAngle - angle : angle - startAngle)
        // A point exactly on the far end is on the arc; the slack is for the
        // rounding in `atan2`, not for a tolerance anyone should tune.
        return travelled <= sweep + 1e-12
    }

    /// `angle` folded into `[0, 2π)`.
    private static func wrapped(_ angle: Double) -> Double {
        let turn = 2 * Double.pi
        let remainder = angle.truncatingRemainder(dividingBy: turn)
        return remainder < 0 ? remainder + turn : remainder
    }
}

// MARK: - Accumulator

/// The running box, so the walk above reads as a list of what each segment
/// contributes rather than as four `min`/`max` pairs per case.
private struct Bounds {
    private var minX = Double.infinity
    private var minY = Double.infinity
    private var maxX = -Double.infinity
    private var maxY = -Double.infinity

    mutating func include(_ point: MarkPoint) {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
    }

    mutating func include(_ points: [MarkPoint]) {
        for point in points { include(point) }
    }

    var result: (origin: MarkPoint, width: Double, height: Double)? {
        guard minX <= maxX, minY <= maxY else { return nil }
        return (MarkPoint(minX, minY), maxX - minX, maxY - minY)
    }
}
