import Foundation

/// Why a CBOR body was refused.
///
/// Every case is a refusal rather than a best effort. A decoder that guesses at
/// a malformed body is a decoder that can be steered, and the peer sending the
/// body is not necessarily friendly.
enum CBORError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The item ended before the bytes it declared.
    case truncated
    /// A declared length or element count exceeds what remains in the buffer.
    /// Checked before a single byte is allocated.
    case lengthExceedsBuffer(declared: UInt64, remaining: Int)
    /// A length or count that will not fit in `Int` on this platform.
    case lengthUnrepresentable(declared: UInt64)
    /// More items than ``SyncLimits/maximumWireItemCount``.
    ///
    /// Distinct from ``lengthExceedsBuffer(declared:remaining:)``: that one
    /// proves the declared bytes exist, and this one bounds what those bytes
    /// are allowed to cost, since a one-byte `null` is a whole `CBORValue`.
    case itemBudgetExhausted
    /// RFC 8949 §4.2.1 preferred serialization: an argument written in a wider
    /// head than the value needs. ``CBOREncoder`` emits only the shortest form,
    /// so a wider one is a second encoding of a message that already has one.
    case nonCanonicalArgument(additional: UInt8, argument: UInt64)
    /// RFC 8949 §4.2.1: map keys out of the bytewise lexicographic order of
    /// their own encodings. Also how a byte-identical duplicate key is caught,
    /// since equal encodings do not precede one another.
    case mapKeysOutOfOrder
    /// Additional information 31 on a string, array or map. This protocol never
    /// emits indefinite-length items, so accepting them would be attack surface
    /// for nothing.
    case indefiniteLengthRejected(majorType: UInt8)
    /// Additional information 28, 29 or 30 — reserved by RFC 8949 §3 and not
    /// well-formed in the present version of CBOR.
    case reservedAdditionalInformation(UInt8)
    /// A major type or simple value outside this protocol's subset: a float, a
    /// tag, a break stop code, an unassigned simple value.
    case unsupportedItem(initialByte: UInt8)
    /// A text string whose bytes are not valid UTF-8.
    case invalidUTF8
    /// RFC 8949 §5.6: a map with duplicate keys is not valid.
    case duplicateMapKey
    /// Nesting deeper than ``SyncLimits/maximumWireNestingDepth``. Rejected
    /// before recursing, so a nested-container bomb throws rather than
    /// overflowing the stack.
    case nestingTooDeep
    /// Bytes remain after a complete item. The body of a frame is exactly one
    /// item, so trailing bytes mean the framing and the body disagree.
    case trailingBytes(count: Int)
    /// The body decoded, but not into the shape the message type requires.
    case unexpectedShape(String)

    var description: String {
        switch self {
        case .truncated:
            "the item ended before the bytes it declared"
        case .lengthExceedsBuffer(let declared, let remaining):
            "declared length \(declared) exceeds the \(remaining) bytes remaining"
        case .lengthUnrepresentable(let declared):
            "declared length \(declared) is larger than this platform can index"
        case .itemBudgetExhausted:
            "body decodes into more than \(SyncLimits.maximumWireItemCount) items"
        case .nonCanonicalArgument(let additional, let argument):
            "argument \(argument) is written in head \(additional), wider than RFC 8949 §4.2.1 allows"
        case .mapKeysOutOfOrder:
            "map keys are not in the bytewise order of their encodings, per RFC 8949 §4.2.1"
        case .indefiniteLengthRejected(let majorType):
            "indefinite-length item (major type \(majorType)) is not part of this protocol"
        case .reservedAdditionalInformation(let value):
            "additional information \(value) is reserved by RFC 8949 §3"
        case .unsupportedItem(let initialByte):
            "initial byte 0x\(String(initialByte, radix: 16)) is outside this protocol's subset"
        case .invalidUTF8:
            "text string is not valid UTF-8"
        case .duplicateMapKey:
            "map has duplicate keys, which RFC 8949 §5.6 makes invalid"
        case .nestingTooDeep:
            "nesting exceeds \(SyncLimits.maximumWireNestingDepth) levels"
        case .trailingBytes(let count):
            "\(count) bytes remain after a complete item"
        case .unexpectedShape(let detail):
            "unexpected shape: \(detail)"
        }
    }
}
