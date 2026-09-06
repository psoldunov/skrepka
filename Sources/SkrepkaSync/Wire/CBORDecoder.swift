import Foundation

/// Decodes the ``CBORValue`` subset from bytes, per RFC 8949 §3.
///
/// Written against a hostile peer rather than a cooperative one. Four
/// properties, each of which has a test:
///
/// - **Every declared length is checked against the bytes that remain** before
///   anything is allocated. A nine-byte body can declare an array of 2^44
///   elements; a decoder that reserves capacity for that count before reading
///   the elements is remote memory exhaustion, and a frame-size cap does not
///   help because a tiny body can declare a huge length.
/// - **The total item count is bounded too**, at
///   ``SyncLimits/maximumWireItemCount``. Bounding each length against the
///   bytes left does not bound their product: every remaining byte can honestly
///   become one `CBORValue`, and a `CBORValue` costs sixteen bytes of payload,
///   so a maximum-sized frame of `0xf6` inflates about twentyfold in memory
///   without ever declaring a length it cannot back.
/// - **Indefinite-length items are refused outright.** This protocol never
///   emits them, so accepting them would be attack surface for nothing.
/// - **Nesting is bounded and checked before recursing**, so a nested-container
///   bomb throws rather than overflowing the stack — a crash no `catch` can
///   reach.
/// - **Only the canonical encoding is accepted**, matching ``CBOREncoder``:
///   shortest head per RFC 8949 §4.2.1, map keys in the bytewise order of their
///   encodings. One logical message therefore has exactly one valid encoding on
///   both halves of the codec rather than only on the writing half.
/// - **Decoding is total.** Every malformed input throws; none traps. No
///   force-unwrap, no unchecked arithmetic on a wire value.
enum CBORDecoder {
    /// Decodes exactly one item and requires the buffer to hold nothing else.
    ///
    /// A frame's body is one item by definition, so trailing bytes mean the
    /// framing and the body disagree about where the body ended — which is
    /// worth refusing rather than ignoring.
    static func decode(_ data: Data) throws -> CBORValue {
        var cursor = ByteCursor(data)
        var budget = SyncLimits.maximumWireItemCount
        let value = try decodeItem(&cursor, depth: 0, budget: &budget)
        guard cursor.isAtEnd else { throw CBORError.trailingBytes(count: cursor.remaining) }
        return value
    }

    // The mirror of ``CBOREncoder/append(_:to:depth:)``: one arm per RFC 8949
    // §3 major type, plus the depth guard and the type-7 shortcut. This is
    // hostile-input dispatch, and the property a reviewer checks is that every
    // major type from 0 to 7 is accounted for exactly once — which is visible
    // here and would not be if the table were split across functions.
    // swiftlint:disable:next cyclomatic_complexity
    private static func decodeItem(
        _ cursor: inout ByteCursor,
        depth: Int,
        budget: inout Int
    ) throws -> CBORValue {
        guard depth <= SyncLimits.maximumWireNestingDepth else { throw CBORError.nestingTooDeep }
        // Spent before the item is built rather than after, for the same reason
        // the depth guard fires before recursing: the point is never to hold
        // the item at all.
        guard budget > 0 else { throw CBORError.itemBudgetExhausted }
        budget -= 1

        let initialByte = try cursor.takeByte()
        let majorType = initialByte >> 5
        let additional = initialByte & 0x1f

        // Major type 7 carries no argument in this subset: the three simple
        // values are one byte each and everything else is out of scope.
        if majorType == 7 { return try simpleValue(initialByte: initialByte, additional: additional) }

        let argument = try argument(additional, majorType: majorType, cursor: &cursor)

        switch majorType {
        case 0: return .unsigned(argument)
        case 1: return .negative(argument)
        case 2: return .bytes(try cursor.take(try cursor.boundedCount(argument)))
        case 3: return .text(try decodeText(&cursor, argument: argument))
        case 4: return .array(try decodeArray(&cursor, argument: argument, depth: depth, budget: &budget))
        case 5: return .map(try decodeMap(&cursor, argument: argument, depth: depth, budget: &budget))
        default:
            // Major type 6 is a tag. Nothing in this protocol is tagged —
            // timestamps travel as plain integers precisely so tag 1 handling
            // is not part of the trusted surface.
            throw CBORError.unsupportedItem(initialByte: initialByte)
        }
    }

    /// Reads the argument that follows the initial byte, per RFC 8949 §3.
    ///
    /// Values below 24 are the argument. 24 through 27 name a 1-, 2-, 4- or
    /// 8-byte big-endian argument, each of which must be the shortest form that
    /// holds the value. 28 through 30 are reserved and not well-formed. 31
    /// means indefinite length, which this subset refuses.
    private static func argument(
        _ additional: UInt8,
        majorType: UInt8,
        cursor: inout ByteCursor
    ) throws -> UInt64 {
        let value: UInt64
        switch additional {
        case 0..<24: return UInt64(additional)
        case 24: value = UInt64(try cursor.takeByte())
        case 25: value = try bigEndian(byteCount: 2, cursor: &cursor)
        case 26: value = try bigEndian(byteCount: 4, cursor: &cursor)
        case 27: value = try bigEndian(byteCount: 8, cursor: &cursor)
        case 31: throw CBORError.indefiniteLengthRejected(majorType: majorType)
        default: throw CBORError.reservedAdditionalInformation(additional)
        }
        return try shortest(value, additional: additional)
    }

    /// RFC 8949 §4.2.1 preferred serialization: an argument uses the shortest
    /// of the five head forms that holds it, so `1801` is not a well-formed
    /// spelling of `01`.
    ///
    /// ``CBOREncoder`` already emits only that form. Enforcing it on the way in
    /// as well is what gives one logical message exactly one encoding rather
    /// than five. That costs nothing today — nothing hashes a decoded body,
    /// ``ShortAuthString/derive(publicKeys:pairedAt:)`` hashes sorted keys and a
    /// big-endian timestamp — and it is the difference between deterministic and
    /// silently not the first time anything does.
    private static func shortest(_ value: UInt64, additional: UInt8) throws -> UInt64 {
        // The largest value the *next* form down could have carried. Only 24
        // through 27 reach here; the inline arguments below 24 need no check.
        let ceiling: UInt64 =
            switch additional {
            case 24: 23
            case 25: 0xff
            case 26: 0xffff
            default: 0xffff_ffff
            }
        guard value > ceiling else {
            throw CBORError.nonCanonicalArgument(additional: additional, argument: value)
        }
        return value
    }

    private static func bigEndian(byteCount: Int, cursor: inout ByteCursor) throws -> UInt64 {
        guard cursor.remaining >= byteCount else { throw CBORError.truncated }
        var value: UInt64 = 0
        for _ in 0..<byteCount { value = (value << 8) | UInt64(try cursor.takeByte()) }
        return value
    }

    private static func decodeText(_ cursor: inout ByteCursor, argument: UInt64) throws -> String {
        let bytes = try cursor.take(try cursor.boundedCount(argument))
        guard let string = String(data: bytes, encoding: .utf8) else { throw CBORError.invalidUTF8 }
        return string
    }

    /// The count is bounded against remaining bytes before a single element is
    /// read, because the shortest possible element is one byte — so a count
    /// larger than the bytes left cannot be honest, whatever those bytes say.
    /// Capacity is never reserved from it.
    ///
    /// That bound is per-container and says nothing about the total, which is
    /// why every element also spends from `budget`: a single honest count of
    /// 33.5 million one-byte nulls is what
    /// ``SyncLimits/maximumWireItemCount`` exists to refuse.
    private static func decodeArray(
        _ cursor: inout ByteCursor,
        argument: UInt64,
        depth: Int,
        budget: inout Int
    ) throws -> [CBORValue] {
        let count = try cursor.boundedCount(argument)
        var elements: [CBORValue] = []
        for _ in 0..<count {
            elements.append(try decodeItem(&cursor, depth: depth + 1, budget: &budget))
        }
        return elements
    }

    /// A map of `n` pairs is `2n` items, so the honest bound is half the bytes
    /// that remain.
    ///
    /// Keys must arrive in the bytewise lexicographic order of their own
    /// encodings, per RFC 8949 §4.2.1 — which is why the key's bytes are taken
    /// off the cursor rather than re-encoded from the decoded value. A key that
    /// does not *precede* its predecessor is refused, so a byte-identical
    /// duplicate is caught here rather than by ``CBORError/duplicateMapKey``.
    ///
    /// ``CBORError/duplicateMapKey`` still fires, for keys whose encodings
    /// differ but whose decoded values do not: `CBORValue.text` hashes by Swift
    /// `String` equality, which is Unicode canonical equivalence, so `"café"`
    /// in NFC and in NFD are two keys to RFC 8949 §5.6 and one key to
    /// `Dictionary`. No key this protocol uses is accented, and the narrower
    /// rule is the safe direction: it refuses a body the RFC allows rather than
    /// accepting one it does not.
    private static func decodeMap(
        _ cursor: inout ByteCursor,
        argument: UInt64,
        depth: Int,
        budget: inout Int
    ) throws -> [CBORValue: CBORValue] {
        guard let pairCount = Int(exactly: argument) else {
            throw CBORError.lengthUnrepresentable(declared: argument)
        }
        guard pairCount <= cursor.remaining / 2 else {
            throw CBORError.lengthExceedsBuffer(declared: argument, remaining: cursor.remaining)
        }

        var pairs: [CBORValue: CBORValue] = [:]
        var previousKey: Data?
        for _ in 0..<pairCount {
            let start = cursor.position
            let key = try decodeItem(&cursor, depth: depth + 1, budget: &budget)
            let encodedKey = cursor.bytes(from: start)
            if let previousKey, !previousKey.lexicographicallyPrecedes(encodedKey) {
                throw CBORError.mapKeysOutOfOrder
            }
            previousKey = encodedKey
            let value = try decodeItem(&cursor, depth: depth + 1, budget: &budget)
            guard pairs.updateValue(value, forKey: key) == nil else {
                throw CBORError.duplicateMapKey
            }
        }
        return pairs
    }

    /// RFC 8949 §3.3 Table 4. Only `false`, `true` and `null` are in scope;
    /// floats, `undefined` and every unassigned simple value are refused.
    private static func simpleValue(initialByte: UInt8, additional: UInt8) throws -> CBORValue {
        switch additional {
        case 20: return .boolean(false)
        case 21: return .boolean(true)
        case 22: return .null
        default: throw CBORError.unsupportedItem(initialByte: initialByte)
        }
    }
}
