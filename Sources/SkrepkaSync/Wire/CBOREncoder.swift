import Foundation

/// Canonical CBOR encoding of ``CBORValue``, per RFC 8949 §3 (major types and
/// the head) and §4.2.1 (core deterministic encoding requirements).
///
/// Deterministic is not a nicety here. Phase 2's short authentication string is
/// a hash over encoded bytes, so two peers encoding the same value must produce
/// byte-identical output or the two devices display different codes and the
/// user cannot pair them. §4.2.1 gives exactly two rules that matter for this
/// subset:
///
/// - **Preferred serialization.** Every argument — integer values and the
///   lengths of major types 2 through 5 — uses the shortest of the five forms
///   that holds it.
/// - **Sorted map keys.** Keys appear in bytewise lexicographic order of their
///   own encodings.
///
/// Indefinite-length items are unrepresentable in ``CBORValue``, which
/// satisfies §4.2.1's third rule by construction.
enum CBOREncoder {
    static func encode(_ value: CBORValue) throws -> Data {
        var output = Data()
        try append(value, to: &output, depth: 0)
        return output
    }

    // One arm per RFC 8949 §3 major type, which is what makes this readable as
    // the specification's table rather than as logic. The arm count is fixed by
    // the standard, not by this function, and splitting it would put half the
    // table somewhere else — the encoder is the thing a reviewer diffs against
    // ``CBORDecoder``, so it stays whole.
    // swiftlint:disable:next cyclomatic_complexity
    private static func append(_ value: CBORValue, to output: inout Data, depth: Int) throws {
        guard depth <= SyncLimits.maximumWireNestingDepth else { throw CBORError.nestingTooDeep }

        switch value {
        case .unsigned(let argument):
            appendHead(majorType: 0, argument: argument, to: &output)
        case .negative(let argument):
            appendHead(majorType: 1, argument: argument, to: &output)
        case .bytes(let data):
            appendHead(majorType: 2, argument: UInt64(data.count), to: &output)
            output.append(data)
        case .text(let string):
            let utf8 = Data(string.utf8)
            appendHead(majorType: 3, argument: UInt64(utf8.count), to: &output)
            output.append(utf8)
        case .array(let elements):
            appendHead(majorType: 4, argument: UInt64(elements.count), to: &output)
            for element in elements { try append(element, to: &output, depth: depth + 1) }
        case .map(let pairs):
            try appendMap(pairs, to: &output, depth: depth)
        case .boolean(let flag):
            // RFC 8949 §3.3 Table 4: simple value 20 is false, 21 is true.
            output.append(flag ? 0xf5 : 0xf4)
        case .null:
            // RFC 8949 §3.3 Table 4: simple value 22.
            output.append(0xf6)
        }
    }

    /// Encodes the keys first, then sorts by those bytes, per §4.2.1.
    ///
    /// Sorting the encodings rather than the keys is what makes the order
    /// independent of `Dictionary`'s iteration, which is seeded per process and
    /// would otherwise put two peers' output in different orders.
    private static func appendMap(
        _ pairs: [CBORValue: CBORValue],
        to output: inout Data,
        depth: Int
    ) throws {
        var encoded: [(key: Data, value: CBORValue)] = []
        encoded.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            var keyBytes = Data()
            try append(key, to: &keyBytes, depth: depth + 1)
            encoded.append((keyBytes, value))
        }
        encoded.sort { $0.key.lexicographicallyPrecedes($1.key) }

        appendHead(majorType: 5, argument: UInt64(encoded.count), to: &output)
        for pair in encoded {
            output.append(pair.key)
            try append(pair.value, to: &output, depth: depth + 1)
        }
    }

    /// Writes the initial byte and any argument bytes — the item's *head*, in
    /// RFC 8949 §3's term — in the shortest form that holds `argument`.
    ///
    /// The thresholds are §4.2.1's: values below 24 ride in the initial byte,
    /// then `uint8`, `uint16`, `uint32`, `uint64`, signalled by additional
    /// information 24, 25, 26 and 27 respectively.
    private static func appendHead(majorType: UInt8, argument: UInt64, to output: inout Data) {
        let prefix = majorType << 5
        switch argument {
        case 0..<24:
            output.append(prefix | UInt8(argument))
        case 24...UInt64(UInt8.max):
            output.append(prefix | 24)
            output.append(UInt8(argument))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            output.append(prefix | 25)
            output.append(contentsOf: bigEndianBytes(UInt16(argument)))
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            output.append(prefix | 26)
            output.append(contentsOf: bigEndianBytes(UInt32(argument)))
        default:
            output.append(prefix | 27)
            output.append(contentsOf: bigEndianBytes(argument))
        }
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.bigEndian) { Array($0) }
    }
}
