import Foundation
import Testing

@testable import SkrepkaCore

/// ``MarkPath/boundingBox`` against shapes whose true extent can be worked out
/// by hand.
///
/// Platform-free on purpose. ``PaperclipPathTests`` already pins this box
/// against `CGPath.boundingBoxOfPath`, which is the agreement that matters —
/// but that test needs Core Graphics, so on Linux, where the box is the *only*
/// thing a Cairo renderer would have to fit against, nothing would look at it
/// at all. These cases run everywhere.
@Suite("Mark path bounds")
struct MarkPathBoundsTests {
    private static let tolerance = 1e-9

    @Test("A cubic is measured by its curve, not by its control points")
    func controlPointsAreNotPartOfTheBox() throws {
        // The regression this suite exists for. Both control points sit at
        // y = 100, and the curve they steer only reaches y = 75: a hull-based
        // box is a third too tall, and a renderer fitting against it draws the
        // mark smaller and off-centre. 300·t·(1−t) peaks at 75, by hand.
        let path = MarkPath(segments: [
            .move(to: MarkPoint(0, 0)),
            .curve(control1: MarkPoint(0, 100), control2: MarkPoint(100, 100), to: MarkPoint(100, 0)),
        ])
        let box = try #require(path.boundingBox)

        #expect(abs(box.origin.x - 0) < Self.tolerance)
        #expect(abs(box.origin.y - 0) < Self.tolerance)
        #expect(abs(box.width - 100) < Self.tolerance)
        #expect(abs(box.height - 75) < Self.tolerance)
    }

    @Test("An arc is measured by the part it sweeps")
    func arcsAreMeasuredByTheirSweep() throws {
        // The top half of a circle of radius 10. Measuring the whole circle
        // would make it twice as tall as it is, which on the paperclip's end
        // caps is how the box picked up 3.6 units of height the mark does not
        // occupy.
        let box = try #require(Self.arc(from: 0, to: .pi).boundingBox)

        #expect(abs(box.origin.x + 10) < Self.tolerance)
        #expect(abs(box.origin.y - 0) < Self.tolerance)
        #expect(abs(box.width - 20) < Self.tolerance)
        #expect(abs(box.height - 10) < Self.tolerance)
    }

    @Test("The same arc swept the other way is the other half")
    func sweepDirectionPicksTheOtherHalf() throws {
        // Between the same two angles, clockwise is the bottom half. A sweep
        // test that normalised to the shorter turn would return the top half
        // for both and never be noticed on a symmetrical mark.
        let box = try #require(Self.arc(from: 0, to: .pi, clockwise: true).boundingBox)

        #expect(abs(box.origin.y + 10) < Self.tolerance)
        #expect(abs(box.height - 10) < Self.tolerance)
    }

    @Test("A full turn is the whole circle, and no turn is a point")
    func fullAndEmptySweeps() throws {
        let round = try #require(Self.arc(from: 0, to: 2 * .pi).boundingBox)
        #expect(abs(round.width - 20) < Self.tolerance)
        #expect(abs(round.height - 20) < Self.tolerance)

        // Equal angles are a degenerate arc rather than a circle — the same
        // distinction `CGMutablePath.addArc` draws, and one wrap away from the
        // case above.
        let point = try #require(Self.arc(from: 0, to: 0).boundingBox)
        #expect(abs(point.width) < Self.tolerance)
        #expect(abs(point.height) < Self.tolerance)
    }

    @Test("A quarter turn reaches one axis extreme, not four")
    func aQuarterTurnTouchesOneAxis() throws {
        // From 3 o'clock to 12, anticlockwise: the box runs from the centre to
        // the radius in both directions and touches the circle at exactly one
        // of the four compass points. Taking all four would give the full
        // circle again.
        let box = try #require(Self.arc(from: 0, to: .pi / 2).boundingBox)

        #expect(abs(box.origin.x - 0) < Self.tolerance)
        #expect(abs(box.origin.y - 0) < Self.tolerance)
        #expect(abs(box.width - 10) < Self.tolerance)
        #expect(abs(box.height - 10) < Self.tolerance)
    }

    @Test("A path that states nothing has no box")
    func anEmptyPathHasNoBox() {
        #expect(MarkPath(segments: []).boundingBox == nil)
        // `.close` alone states no point either.
        #expect(MarkPath(segments: [.close]).boundingBox == nil)
    }

    @Test("Lines and moves are measured as themselves")
    func straightSegmentsAreTheirOwnBox() throws {
        let path = MarkPath(segments: [
            .move(to: MarkPoint(-4, 12)),
            .line(to: MarkPoint(20, -3)),
            .close,
        ])
        let box = try #require(path.boundingBox)

        #expect(abs(box.origin.x + 4) < Self.tolerance)
        #expect(abs(box.origin.y + 3) < Self.tolerance)
        #expect(abs(box.width - 24) < Self.tolerance)
        #expect(abs(box.height - 15) < Self.tolerance)
    }

    // MARK: - Support

    /// A one-arc path on a circle of radius 10 about the origin.
    private static func arc(
        from start: Double,
        to end: Double,
        clockwise: Bool = false
    ) -> MarkPath {
        let arc = MarkArc(
            center: MarkPoint(0, 0),
            radius: 10,
            startAngle: start,
            endAngle: end,
            clockwise: clockwise
        )
        return MarkPath(segments: [.arc(arc)])
    }
}
