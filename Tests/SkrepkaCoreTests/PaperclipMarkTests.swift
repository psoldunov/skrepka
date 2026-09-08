import Foundation
import Testing

@testable import SkrepkaCore

/// Whether the two platforms draw the same mark from the same table (OQ-12) is
/// a platform-free question, so it is answered platform-free: no
/// `CoreGraphics`, so this runs on Linux as well as macOS.
///
/// `PaperclipPathTests` covers what is left that genuinely needs Core
/// Graphics — fitting a `CGPath` into a box, and the flip.
@Suite("Paperclip mark")
struct PaperclipMarkTests {
    @Test("The mark still draws what scripts/paperclip.svg draws")
    func matchesTheDesignSource() throws {
        let svg = try String(contentsOf: Self.designSource, encoding: .utf8)
        let source = try SVGPathParser.path(from: Self.pathData(in: svg))
        let transcribed = PaperclipMark.outline()

        // Segment for segment, control points included — comparing what the two
        // draw is not enough, because a mistyped control point moves the curve
        // by a third of its own error and hides inside antialiasing. Both sides
        // are expanded through the same arc flattening first: the SVG's `A`
        // command already comes out as curves, and ``PaperclipMark``'s round
        // caps are ``MarkSegment/arc`` — expanding them the same way is what
        // makes "segment for segment" a fair comparison instead of an `.arc`
        // failing to line up against two `.curve`s that draw the same cap.
        #expect(Self.commands(of: source) == Self.commands(of: transcribed))

        let stated = Self.points(of: source)
        let written = Self.points(of: transcribed)
        #expect(stated.count == written.count)
        let drift =
            zip(stated, written)
            .map { max(abs($0.x - $1.x), abs($0.y - $1.y)) }
            .max() ?? .greatestFiniteMagnitude
        // Everything agrees exactly except across the two end caps, where the
        // SVG states a radius rounded to three places (57.907) and the Swift
        // derives it from the chord it spans (57.9065). That walks the
        // reconstructed arc by a fraction of a unit in a 1200-unit box, and
        // that is the floor: this catches a dropped segment, a reversed cap and
        // a digit gone astray in the units or tenths place, and cannot see a
        // change too small to draw differently.
        #expect(drift < 0.4)
    }

    @Test("A path command the parser cannot read fails loudly")
    func unreadableSourceThrows() {
        // Guards the test above from passing because the SVG stopped parsing.
        #expect(throws: SVGPathParser.Failure.self) {
            try SVGPathParser.path(from: "M0,0 Q10,10 20,0")
        }
    }

    // MARK: - Support

    /// The repository's own copy, found from this file rather than from the
    /// working directory, which `swift test` makes no promise about.
    private static var designSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/paperclip.svg")
    }

    private static func pathData(in svg: String) throws -> String {
        let opening = try #require(svg.range(of: "d=\""))
        let rest = svg[opening.upperBound...]
        let closing = try #require(rest.firstIndex(of: "\""))
        return String(rest[..<closing])
    }

    private enum Kind: Equatable {
        case move, line, curve, arc, close
    }

    /// Arcs flattened to curves first, via the same construction
    /// ``SVGPathParser`` uses for the SVG's `A` command, so an `.arc` on one
    /// side and its equivalent `.curve`s on the other read as the same shape.
    private static func expanded(_ path: MarkPath) -> [MarkSegment] {
        path.segments.flatMap { segment -> [MarkSegment] in
            guard case .arc(let arc) = segment else { return [segment] }
            return arcToCubicSegments(arc)
        }
    }

    private static func commands(of path: MarkPath) -> [Kind] {
        expanded(path).map { segment in
            switch segment {
            case .move: .move
            case .line: .line
            case .curve: .curve
            case .arc: .arc
            case .close: .close
            }
        }
    }

    /// Every coordinate the path carries, control points included, in the order
    /// it states them.
    private static func points(of path: MarkPath) -> [MarkPoint] {
        expanded(path).flatMap { segment -> [MarkPoint] in
            switch segment {
            case .move(let point), .line(let point):
                [point]
            case .curve(let control1, let control2, let end):
                [control1, control2, end]
            case .arc(let arc):
                [arc.center]
            case .close:
                []
            }
        }
    }
}
