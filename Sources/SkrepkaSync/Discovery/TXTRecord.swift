import Foundation

/// A DNS-SD TXT record, held as ordered `(key, value)` byte pairs.
///
/// Ordered byte pairs rather than a `[String: String]` because the platforms
/// this record has to reach render it differently and one of them cannot
/// express a dictionary of strings. Bonjour takes the RFC 6763 §6.1 wire form,
/// each entry a length byte followed by `key=value`; Avahi's
/// `org.freedesktop.Avahi.EntryGroup.AddService` takes its `txt` argument as
/// `aay` — an array of raw `key=value` byte arrays, with no length prefixes and
/// no promise that the bytes are text. Both encodings fall out of this shape;
/// neither falls out of a dictionary.
///
/// Two things RFC 6763 §6.4 defines that a dictionary also cannot carry, and
/// which this type keeps: an attribute present with *no* value at all, spelled
/// `key` rather than `key=`, and a value whose bytes are not UTF-8.
public struct TXTRecord: Sendable, Hashable {
    /// One `key=value` attribute.
    public struct Entry: Sendable, Hashable {
        public let key: String

        /// `nil` when the attribute carried no `=` at all — "present, no value"
        /// in RFC 6763 §6.4, which is a different statement from `key=`, an
        /// empty value. Bonjour draws the same line between
        /// `NWTXTRecord.Entry.none` and `.empty`.
        public let value: [UInt8]?

        /// Validated here so that no encoder has to re-check, and so that an
        /// over-long entry is refused at the point it is built rather than
        /// silently shortened on its way out.
        public init(key: String, value: [UInt8]?) throws {
            try TXTRecord.validate(key: key)
            let bytes = Entry.encodedSize(key: key, value: value)
            guard bytes <= TXTRecord.maximumEntryBytes else {
                throw TXTRecordError.entryTooLong(key: key, bytes: bytes)
            }
            self.key = key
            self.value = value
        }

        public init(key: String, value: String) throws {
            try self.init(key: key, value: Array(value.utf8))
        }

        /// The `key=value` bytes with no length prefix — exactly one element of
        /// Avahi's `aay`.
        public var rawBytes: [UInt8] {
            guard let value else { return Array(key.utf8) }
            return Array(key.utf8) + [UInt8(ascii: "=")] + value
        }

        /// The value decoded as UTF-8, `nil` when it is absent or is not UTF-8.
        public var stringValue: String? {
            guard let value else { return nil }
            return String(bytes: value, encoding: .utf8)
        }

        /// Bytes on the wire, excluding the length prefix.
        var encodedSize: Int { Entry.encodedSize(key: key, value: value) }

        static func encodedSize(key: String, value: [UInt8]?) -> Int {
            key.utf8.count + (value.map { 1 + $0.count } ?? 0)
        }
    }

    /// RFC 6763 §6.1: one entry is length-prefixed by a single octet, so at
    /// most 255 bytes of `key=value` follow it.
    public static let maximumEntryBytes = 255

    /// RFC 6763 §6.2's advice, taken as a rule: keep the whole record inside a
    /// single 1500-byte Ethernet packet so it never has to be fragmented.
    public static let maximumRecordBytes = 1300

    /// In advertised order. Order is not significant to DNS-SD, but keeping it
    /// makes a record byte-identical across runs, which is what lets a test
    /// pin the encoding.
    public let entries: [Entry]

    /// Builds a record this device will advertise.
    ///
    /// Throws where a peer's record would not: a duplicate key is a bug in the
    /// caller, while a duplicate key arriving from the network is something
    /// RFC 6763 §6.4 says to tolerate.
    public init(_ entries: [Entry]) throws {
        var seen: Set<String> = []
        for entry in entries {
            guard seen.insert(entry.key.lowercased()).inserted else {
                throw TXTRecordError.duplicateKey(entry.key)
            }
        }
        let bytes = entries.reduce(0) { $0 + 1 + $1.encodedSize }
        guard bytes <= Self.maximumRecordBytes else {
            throw TXTRecordError.recordTooLarge(bytes: bytes)
        }
        self.entries = entries
    }

    /// Adopts entries that arrived from a peer.
    ///
    /// Skips exactly the two checks ``init(_:)`` adds for a record *this*
    /// device builds, and which RFC 6763 §6.4 tells a receiver to tolerate: a
    /// duplicate key, which §6.4 says to ignore after the first rather than
    /// reject, and ``maximumRecordBytes``, which is §6.2's advice to a sender
    /// about packet size and not a rule about what may be read.
    ///
    /// Everything ``Entry/init(key:value:)`` enforces still applies — the
    /// decoders in `TXTRecordCoding.swift` build every received entry through
    /// it. That is deliberate: a printable, `=`-free key of at most 255 encoded
    /// bytes is what makes ``dnsSDWireFormat`` able to write its length octet
    /// without a check, and a record decoded from avahi's `aay` and re-encoded
    /// for Bonjour goes down exactly that path. The cost is that one byte
    /// outside 0x20–0x7E in one key rejects that peer's whole record, which is
    /// the trade this build takes: a peer advertising a malformed key is
    /// invisible rather than half-read.
    init(received entries: [Entry]) {
        self.entries = entries
    }

    /// The first entry with this key.
    ///
    /// "First" and "case-insensitive" are both requirements rather than
    /// conveniences: RFC 6763 §6.4 makes keys case-insensitive and tells a
    /// client that receives the same key twice to ignore every occurrence after
    /// the first.
    public func entry(for key: String) -> Entry? {
        let wanted = key.lowercased()
        return entries.first { $0.key.lowercased() == wanted }
    }

    /// Keys present in the record that are not in `known`, lowercased and
    /// sorted.
    ///
    /// Reported rather than rejected. A peer built after this one may advertise
    /// keys this build has no meaning for, and the forward-compatibility rule
    /// the wire layer already follows for `FrameError.unknownMessageType` says
    /// to carry on and surface the fact.
    public func keys(outside known: Set<String>) -> [String] {
        let lowercased = Set(known.map { $0.lowercased() })
        return entries.map { $0.key.lowercased() }.filter { !lowercased.contains($0) }.sorted()
    }

    static func validate(key: String) throws {
        guard !key.isEmpty else { throw TXTRecordError.emptyKey }
        for byte in key.utf8 {
            guard byte != UInt8(ascii: "=") else {
                throw TXTRecordError.keyContainsEquals(key)
            }
            guard byte >= 0x20, byte <= 0x7E else {
                throw TXTRecordError.keyIsNotPrintableASCII(key)
            }
        }
    }
}
