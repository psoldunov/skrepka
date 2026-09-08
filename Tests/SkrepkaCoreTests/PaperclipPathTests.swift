// Core Graphics. Returns with PaperclipPath once OQ-12 settles it — Phase 7.
#if canImport(CoreGraphics)

    import CoreGraphics
    import Foundation
    import Testing

    @testable import SkrepkaCore

    /// The mark is the one drawing the app icon, the menu bar and three SwiftUI
    /// surfaces all share, and none of those can tell you it went wrong: a mirrored
    /// or off-centre clip renders happily and inks exactly as many pixels as a
    /// correct one. So the arithmetic is pinned here.
    ///
    /// The artwork itself — whether the outline still matches
    /// `scripts/paperclip.svg` — is pinned platform-free in
    /// ``PaperclipMarkTests``. What is left here needs Core Graphics: fitting a
    /// `CGPath` into a box, and the flip.
    @Suite("Paperclip path")
    struct PaperclipPathTests {
        private static let box = CGRect(x: 37, y: 11, width: 240, height: 160)

        // MARK: - Fitting

        @Test("The mark fits inside its box, centred, without distorting")
        func fittedSitsCentredInTheBox() throws {
            let bounds = try #require(PaperclipPath.fitted(in: Self.box)).boundingBoxOfPath
            let design = PaperclipPath.outline().boundingBoxOfPath

            #expect(bounds.width <= Self.box.width + 0.001)
            #expect(bounds.height <= Self.box.height + 0.001)
            #expect(abs(bounds.midX - Self.box.midX) < 0.001)
            #expect(abs(bounds.midY - Self.box.midY) < 0.001)
            // Taller than it is wide, so the box's shorter side is what it fills.
            #expect(abs(bounds.height - Self.box.height) < 0.001)
            #expect(abs(bounds.width / bounds.height - design.width / design.height) < 0.0001)
        }

        @Test("Flipping mirrors the mark about the box, and nothing else")
        func flippingIsAMirror() throws {
            // The failure this exists for: a sign error in the flip ships a
            // backwards logo that every other test still passes.
            let upright = Self.points(of: try #require(PaperclipPath.fitted(in: Self.box, flipped: false)))
            let flipped = Self.points(of: try #require(PaperclipPath.fitted(in: Self.box)))

            #expect(upright.count == flipped.count)
            let drift =
                zip(upright, flipped)
                .map { max(abs($0.x - $1.x), abs(2 * Self.box.midY - $0.y - $1.y)) }
                .max() ?? .greatestFiniteMagnitude
            #expect(drift < 1e-9)
        }

        @Test("A degenerate box yields no transform rather than a scale of infinity")
        func degenerateBoundsAreRefused() {
            #expect(PaperclipPath.transform(fitting: .zero, in: Self.box) == nil)
            #expect(
                PaperclipPath.transform(fitting: CGRect(x: 0, y: 0, width: 8, height: 0), in: Self.box) == nil
            )
        }

        @Test("fitted() is the exposed transform applied to the outline")
        func fittedAndTransformAgree() throws {
            // The menu bar draws the mark with `transform(fitting:in:)` directly,
            // because its box has to include the attention badge. If the two ever
            // part company the menu bar mark drifts away from the app's.
            let shape = PaperclipPath.outline()
            var transform = try #require(
                PaperclipPath.transform(fitting: shape.boundingBoxOfPath, in: Self.box)
            )
            let byHand = Self.points(of: try #require(shape.copy(using: &transform)))
            let byHelper = Self.points(of: try #require(PaperclipPath.fitted(in: Self.box)))

            #expect(byHand.count == byHelper.count)
            #expect(zip(byHand, byHelper).allSatisfy { $0.x == $1.x && $0.y == $1.y })
        }

        @Test("Core Graphics sweeps the end caps the way the SVG does")
        func coreGraphicsArcsMatchTheSource() throws {
            // The one thing ``PaperclipMarkTests`` cannot see, and the reason it
            // cannot: that suite expands both sides through the *same* arc
            // flattening, which is right for asking "is the table still the
            // artwork" and blind to what happens when ``MarkSegment/arc``
            // reaches `CGMutablePath.addArc` on this platform. A cap swept the
            // wrong way, or an angle measured from the wrong axis, passes every
            // other test in this repository and ships a paperclip with two
            // bulges pointing inward.
            //
            // Compared as geometry rather than segment for segment, because the
            // two sides legitimately disagree about *decomposition*: the parser
            // splits the SVG's `A` command into 90° cubics, Core Graphics
            // splits `addArc` its own undocumented way, and neither is wrong.
            // The bounding box is what a reversed cap actually moves — the
            // bulge stops sticking out past the wire — so it is what to assert
            // on.
            let svg = try String(contentsOf: Self.designSource, encoding: .utf8)
            let stated = PaperclipPath.render(try SVGPathParser.path(from: Self.pathData(in: svg)))
                .boundingBoxOfPath
            let drawn = PaperclipPath.outline().boundingBoxOfPath

            // One unit in a 1200-unit box. The floor is the same rounding
            // ``PaperclipMarkTests`` documents — the SVG states the cap radius
            // as 57.907 where the Swift derives 57.9065 from the chord — plus
            // the control-point hull the two decompositions do not share. A
            // reversed cap moves an edge by a whole radius, which is fifty
            // times this.
            #expect(abs(stated.minX - drawn.minX) < 1)
            #expect(abs(stated.minY - drawn.minY) < 1)
            #expect(abs(stated.maxX - drawn.maxX) < 1)
            #expect(abs(stated.maxY - drawn.maxY) < 1)
        }

        @Test("The portable bounding box is the one Core Graphics fits against")
        func portableBoundsMatchCoreGraphics() throws {
            // Load-bearing rather than tidy. Both renderers place the mark by
            // dividing a destination rectangle by this box — Core Graphics
            // through `transform(fitting:in:)` above, Cairo through the same
            // arithmetic on `MarkPath.boundingBox`. A box that is looser on one
            // side does not draw a looser mark, it draws a smaller one, offset,
            // on that platform only. Nothing else in the repository can see
            // that: every other test measures one platform against itself.
            //
            // The box this replaced was the control hull, which came out
            // 1103.692 × 1203.635 against Core Graphics' 1084.554 × 1200.000 —
            // 1.77% wide and 0.30% tall. That is the regression this asserts is
            // gone.
            let portable = try #require(PaperclipMark.outline().boundingBox)
            let coreGraphics = PaperclipPath.outline().boundingBoxOfPath

            // Measured agreement is 2.6e-5, and the floor under it is real:
            // Core Graphics flattens `addArc` into cubics before measuring,
            // and the standard quarter-circle approximation falls inside the
            // true circle by ~2.7e-4 of the radius — 0.016 units on these
            // 57.9-unit caps. A thousandth of a unit is forty times the
            // observed drift and twenty thousand times smaller than the hull.
            #expect(abs(portable.origin.x - coreGraphics.minX) < 0.001)
            #expect(abs(portable.origin.y - coreGraphics.minY) < 0.001)
            #expect(abs(portable.width - coreGraphics.width) < 0.001)
            #expect(abs(portable.height - coreGraphics.height) < 0.001)
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

        /// Every coordinate the path carries, control points included, in the order
        /// it states them.
        private static func points(of path: CGPath) -> [CGPoint] {
            var points: [CGPoint] = []
            path.applyWithBlock { element in
                let count =
                    switch element.pointee.type {
                    case .moveToPoint, .addLineToPoint: 1
                    case .addQuadCurveToPoint: 2
                    case .addCurveToPoint: 3
                    default: 0
                    }
                points.append(contentsOf: (0..<count).map { element.pointee.points[$0] })
            }
            return points
        }
    }

#endif
