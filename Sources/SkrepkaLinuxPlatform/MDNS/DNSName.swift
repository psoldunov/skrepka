import Foundation

/// A DNS name as the labels it is made of, each one raw bytes.
///
/// Raw bytes rather than dotted text because an instance name is a label that
/// may itself contain dots, spaces and any UTF-8 (RFC 6763 §4.3), and text
/// would need an escaping convention to say where one label ends. On the wire
/// there is no such question: RFC 1035 §3.1 length-prefixes every label.
struct DNSName: Sendable, Hashable, CustomStringConvertible {
    /// RFC 1035 §2.3.4.
    static let maximumLabelBytes = 63
    static let maximumNameBytes = 255

    let labels: [[UInt8]]

    init(labels: [[UInt8]]) {
        self.labels = labels
    }

    /// Labels given as text, each one a single label however many dots it
    /// holds.
    init(_ labels: String...) {
        self.init(labels: labels.map { Array($0.utf8) })
    }

    init(labelStrings: [String]) {
        self.init(labels: labelStrings.map { Array($0.utf8) })
    }

    /// This name with `label` in front — how an instance name is built on its
    /// service type.
    func prefixed(by label: String) -> DNSName {
        DNSName(labels: [Array(label.utf8)] + labels)
    }

    /// Whether two names are the same name.
    ///
    /// RFC 6762 §16: Multicast DNS compares names case-insensitively for ASCII
    /// letters and byte-for-byte for everything else — "Café" and "café" are
    /// the same name, "CAFÉ" and "café" are not.
    func matches(_ other: DNSName) -> Bool {
        guard labels.count == other.labels.count else { return false }
        return zip(labels, other.labels).allSatisfy { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { Self.fold($0) == Self.fold($1) }
        }
    }

    /// Octets on the wire, uncompressed: a length byte per label plus the
    /// root's zero.
    var wireLength: Int {
        labels.reduce(1) { $0 + 1 + $1.count }
    }

    var description: String {
        labels.map { String(bytes: $0, encoding: .utf8) ?? "\\?" }.joined(separator: ".") + "."
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 : byte
    }
}
