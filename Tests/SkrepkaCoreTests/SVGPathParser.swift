// Builds a CGPath, so it is Core Graphics. Returns with PaperclipPathTests — Phase 7.
#if canImport(CoreGraphics)

    import CoreGraphics
    import Foundation

    /// Builds a `CGPath` out of an SVG `d` attribute, so a test can hold
    /// `scripts/paperclip.svg` against ``PaperclipPath`` instead of trusting the
    /// comment in each file that tells the next editor to keep the two in step.
    ///
    /// It reads exactly what the source art uses — `M m L l C c S s A a Z z`, and
    /// circular arcs only — and throws on anything else. That is the point: an edit
    /// this cannot read fails the test loudly instead of passing quietly.
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
        private let path = CGMutablePath()
        private var current: CGPoint = .zero
        private var subpathStart: CGPoint = .zero
        /// The second control point of the last cubic, which `S`/`s` reflect. Reset
        /// by every other command, because the grammar says an `s` that does not
        /// follow a curve takes the current point as its first control.
        private var lastControl: CGPoint?

        /// - Parameter data: the contents of a `<path d="…">` attribute.
        static func path(from data: String) throws -> CGPath {
            var parser = SVGPathParser(scanner: NumberScanner(data))
            try parser.run()
            return parser.path
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
                path.move(to: current)
            case "L", "l":
                current = try point(relative: command == "l")
                path.addLine(to: current)
            case "Z", "z":
                path.closeSubpath()
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
                    control1: CGPoint(
                        x: 2 * current.x - previous.x,
                        y: 2 * current.y - previous.y
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

        private mutating func addCurve(control1: CGPoint, relative: Bool) throws {
            let control2 = try point(relative: relative)
            let end = try point(relative: relative)
            path.addCurve(to: end, control1: control1, control2: control2)
            lastControl = control2
            current = end
        }

        /// SVG states an arc by where it ends; Core Graphics wants a centre. This is
        /// the conversion from the spec's implementation notes (F.6.5 and F.6.6),
        /// narrowed to the circular case the mark's end caps use.
        private mutating func addArc(relative: Bool) throws {
            let radiusX = try scanner.number()
            let radiusY = try scanner.number()
            _ = try scanner.number()  // x-axis rotation, meaningless for a circle
            let largeArc = try scanner.number() != 0
            let sweep = try scanner.number() != 0
            let end = try point(relative: relative)
            guard abs(radiusX - radiusY) < 1e-9 else { throw Failure.ellipticalArc }

            let half = CGPoint(x: (current.x - end.x) / 2, y: (current.y - end.y) / 2)
            let span = half.x * half.x + half.y * half.y
            // How far the centre sits off the chord's midpoint, perpendicular to it.
            // A radius too small to reach is grown to the chord instead (F.6.6),
            // which puts the centre on the midpoint — the case both end caps hit.
            let reach = radiusX * radiusX - span
            let offset = (reach > 0 ? (reach / span).squareRoot() : 0) * (largeArc == sweep ? -1 : 1)
            let center = CGPoint(
                x: (current.x + end.x) / 2 + offset * half.y,
                y: (current.y + end.y) / 2 - offset * half.x
            )

            path.addArc(
                center: center,
                radius: max(radiusX, span.squareRoot()),
                startAngle: atan2(current.y - center.y, current.x - center.x),
                endAngle: atan2(end.y - center.y, end.x - center.x),
                clockwise: !sweep
            )
            current = end
        }

        private mutating func point(relative: Bool) throws -> CGPoint {
            let x = try scanner.number()
            let y = try scanner.number()
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
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

        mutating func number() throws -> CGFloat {
            skipSeparators()
            var text = sign()
            text += digits(acceptingPoint: true)
            if let marker = peek(), marker == "e" || marker == "E" {
                position += 1
                text += "e" + sign() + digits(acceptingPoint: false)
            }
            guard let value = Double(text) else { throw SVGPathParser.Failure.truncated }
            return CGFloat(value)
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

#endif
