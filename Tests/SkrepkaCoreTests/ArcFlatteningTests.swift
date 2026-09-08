import Foundation
import Testing

@testable import SkrepkaCore

/// ``arcToCubicSegments(_:)`` on its own.
///
/// Pinned separately because of where it is used: ``PaperclipMarkTests``
/// flattens *both* sides of its comparison with this function, so an error
/// inside it — a sweep normalised the wrong way, a `kappa` of the wrong sign, a
/// tangent taken from the wrong axis — appears identically on both sides and
/// cancels. That suite is right to work that way, since it asks whether the
/// coordinate table still matches the SVG rather than whether circles are
/// circles. But it does mean nothing else in the repository looks at this
/// function's output against an actual circle, which is what these tests do.
///
/// Everything here is checked against the definition of an arc rather than
/// against recorded output, so a rewrite of the algorithm passes unchanged and
/// a wrong one cannot.
@Suite("Arc flattening")
struct ArcFlatteningTests {
    private static let center = MarkPoint(37, -11)
    private static let radius = 60.0

    /// `4/3 · tan(θ/4)` at θ = 90°, the constant the construction rests on.
    /// Written out rather than recomputed from the formula under test.
    private static let quarterKappa = 0.5522847498307933

    // MARK: - Shape

    @Test("A quarter turn is one cubic, and every piece is a cubic")
    func aQuarterTurnIsOneCubic() throws {
        let pieces = arcToCubicSegments(Self.arc(from: 0, to: .pi / 2))
        #expect(pieces.count == 1)
        // An `.arc` surviving here would mean the caller flattened nothing, and
        // every comparison built on this function would be vacuous.
        let curves = try #require(Self.replay(pieces, from: Self.arc(from: 0, to: .pi / 2)))
        #expect(curves.count == 1)
    }

    @Test("Longer sweeps split at right angles")
    func longerSweepsSplitAtRightAngles() {
        #expect(arcToCubicSegments(Self.arc(from: 0, to: .pi)).count == 2)
        #expect(arcToCubicSegments(Self.arc(from: 0, to: 3 * .pi / 2)).count == 3)
        #expect(arcToCubicSegments(Self.arc(from: 0, to: 2 * .pi)).count == 4)
    }

    @Test("Clockwise full turns keep four clockwise cubics", arguments: [-2 * Double.pi, 2 * Double.pi])
    func clockwiseFullTurns(end: Double) throws {
        let arc = Self.arc(from: 0, to: end, clockwise: true)
        let curves = try #require(Self.replay(arcToCubicSegments(arc), from: arc))
        #expect(curves.count == 4)
        for (index, curve) in curves.enumerated() {
            let angle = -Double(index + 1) * .pi / 2
            #expect(Self.distance(curve.end, Self.point(at: angle)) < 1e-9)
        }
    }

    @Test("Turning nowhere is not turning all the way round")
    func aZeroSweepIsNotAFullCircle() {
        // The two are one keystroke apart and mean opposite things, which is
        // the same distinction `CGMutablePath.addArc` draws: `(0, 2π)` is a
        // circle and `(0, 0)` is nothing. Flattening a degenerate arc yields a
        // single zero-length piece rather than four.
        #expect(arcToCubicSegments(Self.arc(from: 0, to: 0, clockwise: true)).count == 1)
        #expect(arcToCubicSegments(Self.arc(from: 0, to: 0)).count == 1)
    }

    // MARK: - Geometry

    @Test("Every piece begins and ends on the circle")
    func endpointsAreOnTheCircle() throws {
        for sweep in [Double.pi / 2, .pi, 3 * .pi / 2, 0.7, 2.9] {
            for clockwise in [false, true] {
                let arc = Self.arc(
                    from: 0.4, to: 0.4 + (clockwise ? -sweep : sweep), clockwise: clockwise)
                let curves = try #require(Self.replay(arcToCubicSegments(arc), from: arc))
                for curve in curves {
                    #expect(abs(Self.distance(curve.start, Self.center) - Self.radius) < 1e-9)
                    #expect(abs(Self.distance(curve.end, Self.center) - Self.radius) < 1e-9)
                }
            }
        }
    }

    @Test("The last piece lands on the angle the arc asked for")
    func theSweepEndsWhereItSaidItWould() throws {
        for clockwise in [false, true] {
            let end = clockwise ? 0.4 - 2.9 : 0.4 + 2.9
            let arc = Self.arc(from: 0.4, to: end, clockwise: clockwise)
            let curves = try #require(Self.replay(arcToCubicSegments(arc), from: arc))
            let last = try #require(curves.last)
            #expect(Self.distance(last.end, Self.point(at: end)) < 1e-9)
        }
    }

    @Test("Control points sit one kappa along the endpoint tangents")
    func controlPointsUseTheStandardKappa() throws {
        // Placed on the axes so the tangents are exact and the expected points
        // can be written down rather than derived with the same trigonometry
        // the code under test uses.
        let arc = Self.arc(from: 0, to: .pi / 2)
        let curve = try #require(Self.replay(arcToCubicSegments(arc), from: arc)?.first)
        let reach = Self.quarterKappa * Self.radius

        // Leaves 3 o'clock heading anticlockwise, so the first tangent points
        // straight up and the second points right from the top of the arc.
        #expect(Self.distance(curve.start, MarkPoint(Self.center.x + Self.radius, Self.center.y)) < 1e-9)
        #expect(
            Self.distance(
                curve.control1, MarkPoint(Self.center.x + Self.radius, Self.center.y + reach)) < 1e-9)
        #expect(
            Self.distance(
                curve.control2, MarkPoint(Self.center.x + reach, Self.center.y + Self.radius)) < 1e-9)
        #expect(Self.distance(curve.end, MarkPoint(Self.center.x, Self.center.y + Self.radius)) < 1e-9)
    }

    @Test("The curve stays on the circle between its endpoints")
    func theInteriorTracksTheCircle() throws {
        // The failure the endpoint checks cannot see: a control point of the
        // right length and the wrong sign puts both ends on the circle and bows
        // the middle away from it. A quarter-circle cubic is accurate to about
        // 2.7e-4 of the radius at its own midpoint — 0.016 units here — so this
        // bound has room, while a sign error misses by most of a radius.
        for clockwise in [false, true] {
            let arc = Self.arc(
                from: 1.1, to: clockwise ? 1.1 - .pi : 1.1 + .pi, clockwise: clockwise)
            let curves = try #require(Self.replay(arcToCubicSegments(arc), from: arc))
            for curve in curves {
                for step in 1..<8 {
                    let point = Self.point(onCubic: curve, at: Double(step) / 8)
                    #expect(abs(Self.distance(point, Self.center) - Self.radius) < 0.02)
                }
            }
        }
    }

    @Test("Direction is the arc's, not the shorter way round")
    func sweepFollowsTheStatedDirection() throws {
        // Clockwise and counter-clockwise between the same two angles are
        // different arcs — one a quarter turn, the other three quarters.
        // Normalising to the shorter one would silently redraw an end cap as
        // its complement.
        let up = Self.arc(from: 0, to: .pi / 2)
        let down = Self.arc(from: 0, to: .pi / 2, clockwise: true)
        #expect(arcToCubicSegments(up).count == 1)
        #expect(arcToCubicSegments(down).count == 3)

        let climbing = try #require(Self.replay(arcToCubicSegments(up), from: up)?.first)
        let dropping = try #require(Self.replay(arcToCubicSegments(down), from: down)?.first)
        // Both leave 3 o'clock; one climbs, the other drops.
        #expect(climbing.end.y > Self.center.y)
        #expect(dropping.end.y < Self.center.y)
    }

    // MARK: - Support

    private struct Cubic {
        let start: MarkPoint
        let control1: MarkPoint
        let control2: MarkPoint
        let end: MarkPoint
    }

    /// Walks the flattened pieces the way a renderer would, carrying the
    /// current point from one to the next.
    ///
    /// The first piece starts at the arc's own opening angle — that is the
    /// definition of an arc rather than anything the algorithm chose — and each
    /// piece after it starts where the previous one ended. Anything that is not
    /// a curve makes the whole replay fail rather than being skipped, because a
    /// skipped piece is exactly the kind of hole these tests exist to find.
    private static func replay(_ segments: [MarkSegment], from arc: MarkArc) -> [Cubic]? {
        var current = point(at: arc.startAngle)
        var curves: [Cubic] = []
        for segment in segments {
            guard case .curve(let control1, let control2, let end) = segment else { return nil }
            curves.append(Cubic(start: current, control1: control1, control2: control2, end: end))
            current = end
        }
        return curves
    }

    private static func arc(from start: Double, to end: Double, clockwise: Bool = false) -> MarkArc {
        MarkArc(
            center: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise)
    }

    private static func point(at angle: Double) -> MarkPoint {
        MarkPoint(center.x + radius * cos(angle), center.y + radius * sin(angle))
    }

    private static func distance(_ from: MarkPoint, _ to: MarkPoint) -> Double {
        let acrossX = from.x - to.x
        let acrossY = from.y - to.y
        return (acrossX * acrossX + acrossY * acrossY).squareRoot()
    }

    private static func point(onCubic curve: Cubic, at position: Double) -> MarkPoint {
        let remaining = 1 - position
        func value(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            let opening = remaining * remaining * remaining * p0
            let lead = 3 * remaining * remaining * position * p1
            let trail = 3 * remaining * position * position * p2
            return opening + lead + trail + position * position * position * p3
        }
        return MarkPoint(
            value(curve.start.x, curve.control1.x, curve.control2.x, curve.end.x),
            value(curve.start.y, curve.control1.y, curve.control2.y, curve.end.y)
        )
    }
}
