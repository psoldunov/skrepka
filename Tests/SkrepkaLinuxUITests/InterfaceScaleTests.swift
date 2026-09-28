import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// The interface size's arithmetic: every length the app states goes through
/// it, so a rounding slip here is a picker whose rows no longer add up to the
/// window it is drawn in.
@Suite("Interface size")
struct InterfaceScaleTests {
    private static func scale(_ percent: Int) throws -> InterfaceScale {
        try #require(InterfaceScale(percent: percent))
    }

    @Test("only sizes from the design size to twice it are accepted", arguments: [99, 0, -100, 201, 500])
    func refusesOutOfRange(percent: Int) {
        #expect(InterfaceScale(percent: percent) == nil)
    }

    @Test("every size offered is accepted, smallest first, starting at the design size")
    func choicesAreAccepted() {
        #expect(InterfaceScale.choices.allSatisfy { InterfaceScale(percent: $0) != nil })
        #expect(InterfaceScale.choices == InterfaceScale.choices.sorted())
        #expect(InterfaceScale.choices.first == InterfaceScale.standard.percent)
        #expect(InterfaceScale.accepted.upperBound == InterfaceScale.choices.last)
    }

    @Test(
        "a length grows to the nearest whole pixel",
        arguments: [
            (125, 13, 16), (125, 11, 14), (125, 46, 58), (150, 660, 990), (110, 17, 19), (125, 2, 3),
            (200, 30, 60),
        ] as [(Int, Int32, Int32)])
    func lengthsRound(percent: Int, base: Int32, scaled: Int32) throws {
        #expect(try Self.scale(percent).length(base) == scaled)
    }

    @Test("a hairline stays a hairline at every size", arguments: [-1, 0, 1] as [Int32])
    func hairlinesStay(base: Int32) throws {
        #expect(try Self.scale(200).length(base) == base)
    }

    @Test("the design size changes nothing")
    func standardIsIdentity() {
        let css = ".a { font-size: 13px; padding: 0 16px; box-shadow: 0 6px 16px rgba(0,0,0,0.3); }"
        #expect(InterfaceScale.standard.stylesheet(css) == css)
        #expect(InterfaceScale.standard.gapStylesheet(scope: "window.x").isEmpty)
        #expect(InterfaceScale.standard.length(660) == 660)
    }

    @Test("a stylesheet's lengths grow and nothing else in it does")
    func rewritesLengths() throws {
        let css = """
            .a { font-size: 13px; padding: 0 16px; border: 0.5px solid #ffffff; }
            .b { box-shadow: inset 0 -1px rgba(255,255,255,0.75), 0 6px 16px alpha(#000, 0.3); }
            .c { -gtk-icon-size: 30px; letter-spacing: 0.5px; font-weight: 600; opacity: 0.45; }
            """
        let expected = """
            .a { font-size: 20px; padding: 0 24px; border: 0.5px solid #ffffff; }
            .b { box-shadow: inset 0 -1px rgba(255,255,255,0.75), 0 9px 24px alpha(#000, 0.3); }
            .c { -gtk-icon-size: 45px; letter-spacing: 0.5px; font-weight: 600; opacity: 0.45; }
            """
        #expect(try Self.scale(150).stylesheet(css) == expected)
    }

    @Test("a length written without its leading zero is read whole")
    func bareFractions() throws {
        #expect(
            try Self.scale(200).stylesheet("a { border: .5px; margin: -2px 2.5px; }")
                == "a { border: 0.5px; margin: -4px 5px; }")
    }

    @Test("a gap grows by the difference its box's own spacing does not cover")
    func gapRules() throws {
        let rules = try Self.scale(150).gapStylesheet(scope: "window.x")
        // 11 × 1.5 = 16.5, which rounds to 17: six more than the box's own 11.
        #expect(rules.contains("window.x .skrepka-gap-11 { border-spacing: 6px; }"))
        #expect(rules.contains("window.x .skrepka-gap-2 { border-spacing: 1px; }"))
        // A one-pixel gap is a hairline and stays one.
        #expect(!rules.contains("skrepka-gap-1 "))
    }

    @Test(
        "a box wears a gap class only for a gap the stylesheet can grow", arguments: [0, 33, -4] as [Int32])
    func noClassOutsideTheRange(spacing: Int32) {
        #expect(InterfaceScale.gapClass(spacing) == nil)
    }

    @Test("the widest gap the app draws has a class")
    func widestGapHasAClass() {
        #expect(InterfaceScale.gapClass(18) == "skrepka-gap-18")
        #expect(InterfaceScale.gapClass(1) == "skrepka-gap-1")
    }
}
