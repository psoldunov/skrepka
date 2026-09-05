import Foundation

/// Hex literals for the RFC 8949 test vectors, shared by the suites that pin the
/// codec's behaviour.
///
/// Split out when the strictness tests outgrew `CanonicalCBORTests` and the two
/// suites needed the same reader. A vector is a hex *string* rather than a byte
/// array because that is how RFC 8949 Appendix A writes them, and a
/// transcription is checked against the RFC by eye.
enum CBORVector {
    /// A hex literal in a test vector that is not hex at all — a typo, caught
    /// loudly rather than decoded as zeroes.
    ///
    /// `CustomStringConvertible` so the offending literal reaches the failure
    /// message: a transcription error is found by reading the bytes back, and an
    /// error that will not say which vector was wrong makes that harder than it
    /// needs to be.
    struct NotHexadecimal: Error, CustomStringConvertible {
        let literal: String
        var description: String { "not a hexadecimal test vector: \(literal)" }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(_ literal: String) throws -> Data {
        var data = Data()
        var index = literal.startIndex
        while index < literal.endIndex {
            guard let next = literal.index(index, offsetBy: 2, limitedBy: literal.endIndex),
                let byte = UInt8(literal[index..<next], radix: 16)
            else { throw NotHexadecimal(literal: literal) }
            data.append(byte)
            index = next
        }
        return data
    }
}
