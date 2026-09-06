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

        // MARK: - The design source

        @Test("The path still draws what scripts/paperclip.svg draws")
        func matchesTheDesignSource() throws {
            let svg = try String(contentsOf: Self.designSource, encoding: .utf8)
            let source = try SVGPathParser.path(from: Self.pathData(in: svg))
            let transcribed = PaperclipPath.outline()

            // Segment for segment, control points included — comparing what the two
            // draw is not enough, because a mistyped control point moves the curve
            // by a third of its own error and hides inside antialiasing.
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
            // reconstructed arc by 0.26 units in a 1200-unit box, and that is the
            // floor: this catches a dropped segment, a reversed cap and a digit
            // gone astray in the units or tenths place, and cannot see a change too
            // small to draw differently.
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

        private static func commands(of path: CGPath) -> [CGPathElementType] {
            var commands: [CGPathElementType] = []
            path.applyWithBlock { commands.append($0.pointee.type) }
            return commands
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
