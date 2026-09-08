import Foundation

@testable import SkrepkaCore

/// Builds a `MarkPath` out of an SVG `d` attribute, so a test can hold
/// `scripts/paperclip.svg` against ``PaperclipMark`` instead of trusting the
/// comment in each file that tells the next editor to keep the two in step.
///
/// It reads exactly what the source art uses — `M m L l C c S s A a Z z`, and
/// circular arcs only — and throws on anything else. That is the point: an edit
/// this cannot read fails the test loudly instead of passing quietly.
///
/// Platform-free like the type it builds (OQ-12): no `CoreGraphics`, so this
/// runs on Linux too.
struct SVGPathParser {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(Character)
        case truncated
        case ellipticalArc

        var description: String {
            switch self {
            case .unreadable(let command): "unsupported path command '\(command)'"
            case .truncated: "path data ran out mid-command"
            case .ellipticalArc: "elliptical arc: the mark's end caps are circular"
            }
        }
    }

    private var scanner: NumberScanner
    private var segments: [MarkSegment] = []
    private var current: MarkPoint = MarkPoint(0, 0)
    private var subpathStart: MarkPoint = MarkPoint(0, 0)
    /// The second control point of the last cubic, which `S`/`s` reflect. Reset
    /// by every other command, because the grammar says an `s` that does not
    /// follow a curve takes the current point as its first control.
    private var lastControl: MarkPoint?

    /// - Parameter data: the contents of a `<path d="…">` attribute.
    static func path(from data: String) throws -> MarkPath {
        var parser = SVGPathParser(scanner: NumberScanner(data))
        try parser.run()
        return MarkPath(segments: parser.segments)
    }

    private mutating func run() throws {
        var command: Character = " "
        while true {
            if let next = scanner.command() {
                command = next
            } else if scanner.hasNumber() {
                command = Self.repeating(command)
            } else {
                return
            }
            try apply(command)
        }
    }

    /// A command letter carries over until the next one appears, and a repeated
    /// move is a line — the SVG grammar says so.
    private static func repeating(_ command: Character) -> Character {
        switch command {
        case "M": "L"
        case "m": "l"
        default: command
        }
    }

    // MARK: - Commands

    private mutating func apply(_ command: Character) throws {
        if try applyStraight(command) { return }
        if try applyCurved(command) { return }
        throw Failure.unreadable(command)
    }

    private mutating func applyStraight(_ command: Character) throws -> Bool {
        switch command {
        case "M", "m":
            current = try point(relative: command == "m")
            subpathStart = current
            segments.append(.move(to: current))
        case "L", "l":
            current = try point(relative: command == "l")
            segments.append(.line(to: current))
        case "Z", "z":
            segments.append(.close)
            current = subpathStart
        default:
            return false
        }
        lastControl = nil
        return true
    }

    private mutating func applyCurved(_ command: Character) throws -> Bool {
        switch command {
        case "C", "c":
            let relative = command == "c"
            let control1 = try point(relative: relative)
            try addCurve(control1: control1, relative: relative)
        case "S", "s":
            let previous = lastControl ?? current
            try addCurve(
                control1: MarkPoint(
                    2 * current.x - previous.x,
                    2 * current.y - previous.y
                ),
                relative: command == "s"
            )
        case "A", "a":
            try addArc(relative: command == "a")
            lastControl = nil
        default:
            return false
        }
        return true
    }

    private mutating func addCurve(control1: MarkPoint, relative: Bool) throws {
        let control2 = try point(relative: relative)
        let end = try point(relative: relative)
        segments.append(.curve(control1: control1, control2: control2, to: end))
        lastControl = control2
        current = end
    }

    /// SVG states an arc by where it ends; the centre-parameterised form this
    /// needs is the conversion from the spec's implementation notes (F.6.5 and
    /// F.6.6), narrowed to the circular case the mark's end caps use.
    ///
    /// The arc itself is appended as cubic Béziers, not as a ``MarkSegment/arc``
    /// — see ``arcToCubicSegments(_:)`` for why that is the one piece of
    /// geometry worth sharing with the test that reads ``PaperclipMark``'s own
    /// arcs.
    private mutating func addArc(relative: Bool) throws {
        let radiusX = try scanner.number()
        let radiusY = try scanner.number()
        _ = try scanner.number()  // x-axis rotation, meaningless for a circle
        let largeArc = try scanner.number() != 0
        let sweep = try scanner.number() != 0
        let end = try point(relative: relative)
        guard abs(radiusX - radiusY) < 1e-9 else { throw Failure.ellipticalArc }

        let half = MarkPoint((current.x - end.x) / 2, (current.y - end.y) / 2)
        let span = half.x * half.x + half.y * half.y
        // How far the centre sits off the chord's midpoint, perpendicular to it.
        // A radius too small to reach is grown to the chord instead (F.6.6),
        // which puts the centre on the midpoint — the case both end caps hit.
        let reach = radiusX * radiusX - span
        let offset = (reach > 0 ? (reach / span).squareRoot() : 0) * (largeArc == sweep ? -1 : 1)
        let center = MarkPoint(
            (current.x + end.x) / 2 + offset * half.y,
            (current.y + end.y) / 2 - offset * half.x
        )
        let radius = max(radiusX, span.squareRoot())
        let startAngle = atan2(current.y - center.y, current.x - center.x)
        let endAngle = atan2(end.y - center.y, end.x - center.x)

        let arc = MarkArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: !sweep
        )
        segments.append(contentsOf: arcToCubicSegments(arc))
        current = end
    }

    private mutating func point(relative: Bool) throws -> MarkPoint {
        let x = try scanner.number()
        let y = try scanner.number()
        return relative ? MarkPoint(current.x + x, current.y + y) : MarkPoint(x, y)
    }
}

// MARK: - Arc flattening

/// Approximates a circular arc as cubic Bézier segments, splitting at 90°
/// intervals — the standard construction (control points at
/// `4/3 * tan(span/4)` along the endpoint tangents), accurate to a small
/// fraction of a unit at this radius.
///
/// Shared rather than private to ``SVGPathParser``: `PaperclipMarkTests`
/// flattens ``PaperclipMark``'s ``MarkSegment/arc`` end caps with this same
/// function before comparing them against what this parser reads from the SVG.
/// Using one algorithm on both sides is what makes "same coordinates" a
/// meaningful comparison instead of two different approximations of the same
/// circle happening to land close together.
func arcToCubicSegments(_ arc: MarkArc) -> [MarkSegment] {
    let (center, radius, startAngle) = (arc.center, arc.radius, arc.startAngle)
    let sweep = arc.clockwise ? -arc.sweep : arc.sweep

    let pieces = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
    let step = sweep / Double(pieces)

    return (0..<pieces).map { index in
        let start = startAngle + step * Double(index)
        let end = start + step
        let kappa = 4.0 / 3.0 * tan((end - start) / 4)
        let from = MarkPoint(center.x + radius * cos(start), center.y + radius * sin(start))
        let to = MarkPoint(center.x + radius * cos(end), center.y + radius * sin(end))
        let control1 = MarkPoint(
            from.x - kappa * radius * sin(start), from.y + kappa * radius * cos(start))
        let control2 = MarkPoint(
            to.x + kappa * radius * sin(end), to.y - kappa * radius * cos(end))
        return .curve(control1: control1, control2: control2, to: to)
    }
}

// MARK: - Tokens

/// Reads command letters and numbers out of path data, which separates numbers
/// with a comma, a space, or nothing at all when the next one opens with a sign
/// or a second decimal point.
private struct NumberScanner {
    private let characters: [Character]
    private var position = 0

    init(_ text: String) {
        characters = Array(text)
    }

    /// The next command letter, or `nil` when a number comes first.
    mutating func command() -> Character? {
        skipSeparators()
        guard let next = peek(), next.isLetter else { return nil }
        position += 1
        return next
    }

    mutating func hasNumber() -> Bool {
        skipSeparators()
        guard let next = peek() else { return false }
        return isDigit(next) || next == "-" || next == "+" || next == "."
    }

    mutating func number() throws -> Double {
        skipSeparators()
        var text = sign()
        text += digits(acceptingPoint: true)
        if let marker = peek(), marker == "e" || marker == "E" {
            position += 1
            text += "e" + sign() + digits(acceptingPoint: false)
        }
        guard let value = Double(text) else { throw SVGPathParser.Failure.truncated }
        return value
    }

    private mutating func sign() -> String {
        guard let next = peek(), next == "-" || next == "+" else { return "" }
        position += 1
        return String(next)
    }

    /// Digits, stopping at a second decimal point: `.5.5` is two numbers.
    private mutating func digits(acceptingPoint: Bool) -> String {
        var text = ""
        var seenPoint = false
        while let next = peek() {
            if isDigit(next) {
                text.append(next)
            } else if next == "." && acceptingPoint && !seenPoint {
                seenPoint = true
                text.append(next)
            } else {
                break
            }
            position += 1
        }
        return text
    }

    private func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private func peek() -> Character? {
        position < characters.count ? characters[position] : nil
    }

    private mutating func skipSeparators() {
        while let next = peek(), next == "," || next.isWhitespace {
            position += 1
        }
    }
}
