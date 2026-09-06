import Foundation

/// Why a DNS-SD TXT record was refused, named far enough for a caller to tell a
/// record this device built wrong from one a peer sent wrong.
///
/// The split matters because the two directions have different failure sets.
/// ``recordTooLarge(bytes:)`` and ``duplicateKey(_:)`` can only happen while
/// *building* a record: RFC 6763 §6.4 tells a client to keep a duplicate rather
/// than reject it, and a record's total size is not something a peer can be
/// refused for. ``truncated`` can only happen while *reading* one.
/// ``entryTooLong(key:bytes:)`` happens in both directions but not on both
/// paths — an entry read back from the DNS-SD wire form cannot exceed 255
/// bytes, because its length is one octet, while one read from avahi's `aay`
/// arrives as an unbounded byte array and can.
public enum TXTRecordError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A key with no characters. RFC 6763 §6.4 requires at least one.
    case emptyKey

    /// A key containing `=`, which is the separator and so cannot appear in the
    /// name it separates.
    case keyContainsEquals(String)

    /// A key outside printable US-ASCII, which RFC 6763 §6.4 restricts keys to.
    ///
    /// Also how a key whose bytes are not valid UTF-8 arrives: the bytes are
    /// decoded leniently, so the replacement characters they become fail this
    /// check rather than needing a case of their own.
    case keyIsNotPrintableASCII(String)

    /// One `key=value` string over the 255-byte limit of RFC 6763 §6.1.
    ///
    /// Thrown rather than truncated. A silently shortened value is a value that
    /// decodes to something other than what was advertised, and the identifier
    /// this record carries is the thing authentication rests on.
    case entryTooLong(key: String, bytes: Int)

    /// The whole record over ``TXTRecord/maximumRecordBytes``.
    case recordTooLarge(bytes: Int)

    /// The same key twice in a record this device is building.
    case duplicateKey(String)

    /// A length byte claiming more bytes than the record holds.
    case truncated

    public var description: String {
        switch self {
        case .emptyKey:
            "TXT entry has no key"
        case .keyContainsEquals(let key):
            "TXT key \"\(key)\" contains the '=' separator"
        case .keyIsNotPrintableASCII(let key):
            "TXT key \"\(key)\" is not printable US-ASCII"
        case .entryTooLong(let key, let bytes):
            "TXT entry \"\(key)\" is \(bytes) bytes, over the \(TXTRecord.maximumEntryBytes) limit"
        case .recordTooLarge(let bytes):
            "TXT record is \(bytes) bytes, over the \(TXTRecord.maximumRecordBytes) limit"
        case .duplicateKey(let key):
            "TXT key \"\(key)\" appears more than once"
        case .truncated:
            "TXT record ends inside an entry"
        }
    }
}
