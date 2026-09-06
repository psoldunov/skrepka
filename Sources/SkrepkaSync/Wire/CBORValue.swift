import Foundation

/// The subset of CBOR (RFC 8949) this protocol carries.
///
/// Deliberately not every CBOR type. The wire format needs unsigned and
/// negative integers, byte strings, UTF-8 text strings, definite-length arrays
/// and maps, and the three simple values `false`, `true` and `null` — and
/// nothing else. Floats, tags, indefinite-length items and the remaining simple
/// values are not representable here, which means the decoder rejects them
/// rather than interpreting them, and attack surface the protocol never uses
/// does not exist.
///
/// The map is a `Dictionary` rather than a list of pairs because RFC 8949 §5.6
/// makes duplicate keys invalid; representing them would be representing
/// something the decoder must refuse anyway.
///
/// Internal on purpose: `SyncMessage` is the vocabulary above this layer and
/// `Data` is the vocabulary below it, so nothing outside `Wire/` names CBOR.
enum CBORValue: Sendable, Hashable {
    /// Major type 0. The value is the argument.
    case unsigned(UInt64)
    /// Major type 1. The value is `-1 - argument`, held as the argument so the
    /// full range down to `-2^64` survives a round trip.
    case negative(UInt64)
    /// Major type 2.
    case bytes(Data)
    /// Major type 3.
    case text(String)
    /// Major type 4, definite length only.
    case array([CBORValue])
    /// Major type 5, definite length only.
    case map([CBORValue: CBORValue])
    /// Major type 7, simple values 20 and 21.
    case boolean(Bool)
    /// Major type 7, simple value 22.
    case null
}

// MARK: - Building

extension CBORValue {
    /// Wraps a signed integer, choosing the major type RFC 8949 §3.1 requires.
    static func integer(_ value: Int64) -> CBORValue {
        guard value < 0 else { return .unsigned(UInt64(value)) }
        // The encoding is -1 - value; computed on the magnitude so Int64.min
        // does not overflow on the way in.
        return .negative(value.magnitude - 1)
    }

    /// Wraps a value that may be absent. Absence is `null` rather than a
    /// missing key, so every message has one map shape regardless of what it
    /// carries.
    static func optional(_ value: CBORValue?) -> CBORValue { value ?? .null }

    /// Builds a map from string keys. The encoder sorts them, so the order
    /// given here is a readability choice and nothing more.
    static func map(fields: KeyValuePairs<String, CBORValue>) -> CBORValue {
        var result: [CBORValue: CBORValue] = [:]
        for (key, value) in fields { result[.text(key)] = value }
        return .map(result)
    }
}

// MARK: - Reading

extension CBORValue {
    /// The signed integer this value denotes, or `nil` if it is not an integer
    /// or does not fit in one.
    ///
    /// Returns `nil` rather than trapping on the out-of-range cases: the
    /// argument arrived off the wire, where `2^64 - 1` is as easy to write as
    /// `1`.
    var integerValue: Int64? {
        switch self {
        case .unsigned(let argument):
            return Int64(exactly: argument)
        case .negative(let argument):
            // -1 - argument. Bounded first so neither side of the subtraction
            // leaves the range; at the bound the result is exactly Int64.min.
            guard argument <= UInt64(Int64.max) else { return nil }
            return -1 - Int64(argument)
        default:
            return nil
        }
    }
}
