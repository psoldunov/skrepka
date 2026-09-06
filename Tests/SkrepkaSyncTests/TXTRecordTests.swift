import Foundation
import Testing

@testable import SkrepkaSync

/// The encoding both discovery back ends share.
///
/// Worth its own suite because every failure here is silent: a truncated value
/// still registers, a dropped entry still browses, and the only symptom is a
/// peer that never pairs.
@Suite("DNS-SD TXT record")
struct TXTRecordTests {
    static func record(_ pairs: [(String, String)]) throws -> TXTRecord {
        try TXTRecord(pairs.map { try TXTRecord.Entry(key: $0.0, value: $0.1) })
    }

    @Test("The wire form round-trips, byte for byte")
    func wireFormRoundTrip() throws {
        let record = try Self.record([("txtvers", "1"), ("id", "abc"), ("plat", "macos")])
        let encoded = record.dnsSDWireFormat

        // Length octet then `key=value`, per RFC 6763 §6.1.
        #expect(Array(encoded.prefix(10)) == Array("\u{09}txtvers=1".utf8))
        #expect(encoded.count == (1 + 9) + (1 + 6) + (1 + 10))

        let decoded = try TXTRecord(dnsSDWireFormat: encoded)
        #expect(decoded == record)
        #expect(decoded.dnsSDWireFormat == encoded)
    }

    /// Avahi's `AddService` takes `txt` as `aay`, so the entries arrive as
    /// separate byte arrays with no length prefixes. Phase 6 depends on this.
    @Test("The avahi form carries the same pairs without length prefixes")
    func avahiRoundTrip() throws {
        let record = try Self.record([("id", "abc"), ("proto", "1")])
        #expect(record.avahiEntries == [Array("id=abc".utf8), Array("proto=1".utf8)])
        #expect(try TXTRecord(avahiEntries: record.avahiEntries) == record)
    }

    /// The limit is enforced rather than applied. A silently shortened value is
    /// a value that decodes to something other than what was advertised, and
    /// `id=` is what authentication rests on.
    @Test("An entry over 255 bytes throws instead of being truncated")
    func enforcesTheEntryLimit() throws {
        let key = "k"
        // One length octet prefixes at most 255 bytes of `key=value`.
        let largestValue = String(repeating: "v", count: 255 - key.utf8.count - 1)
        let largest = try TXTRecord.Entry(key: key, value: largestValue)
        #expect(largest.rawBytes.count == TXTRecord.maximumEntryBytes)

        #expect(throws: TXTRecordError.entryTooLong(key: key, bytes: 256)) {
            try TXTRecord.Entry(key: key, value: largestValue + "v")
        }
    }

    /// Multi-byte values are counted in bytes, not characters — the place a
    /// character count would silently overrun the limit.
    @Test("The limit counts UTF-8 bytes, not characters")
    func countsBytesNotCharacters() throws {
        // "я" is two bytes, so 127 of them plus `k=` is 256.
        let value = String(repeating: "я", count: 127)
        #expect(value.count < TXTRecord.maximumEntryBytes)
        #expect(throws: TXTRecordError.self) { try TXTRecord.Entry(key: "k", value: value) }
    }

    @Test("A key that is not a key is refused")
    func refusesMalformedKeys() throws {
        #expect(throws: TXTRecordError.emptyKey) { try TXTRecord.Entry(key: "", value: "v") }
        #expect(throws: TXTRecordError.keyContainsEquals("a=b")) {
            try TXTRecord.Entry(key: "a=b", value: "v")
        }
        #expect(throws: TXTRecordError.keyIsNotPrintableASCII("имя")) {
            try TXTRecord.Entry(key: "имя", value: "v")
        }
        #expect(throws: TXTRecordError.keyIsNotPrintableASCII("a\u{7F}")) {
            try TXTRecord.Entry(key: "a\u{7F}", value: "v")
        }
    }

    /// Asymmetric on purpose. A duplicate in a record this device builds is a
    /// bug; a duplicate arriving from a peer is something RFC 6763 §6.4 says to
    /// tolerate by keeping the first.
    @Test("A duplicate key is a build error and a read-time first-wins rule")
    func duplicateKeys() throws {
        #expect(throws: TXTRecordError.duplicateKey("id")) {
            try Self.record([("id", "one"), ("id", "two")])
        }

        let received = try TXTRecord(avahiEntries: [Array("id=one".utf8), Array("ID=two".utf8)])
        #expect(received.entries.count == 2)
        #expect(received.entry(for: "id")?.stringValue == "one")
    }

    /// RFC 6763 §6.4 makes keys case-insensitive.
    @Test("Lookup ignores case")
    func lookupIgnoresCase() throws {
        let record = try Self.record([("TxtVers", "1")])
        #expect(record.entry(for: "txtvers")?.stringValue == "1")
        #expect(record.entry(for: "TXTVERS")?.stringValue == "1")
        #expect(record.entry(for: "vers") == nil)
    }

    /// RFC 6763 §6.4 distinguishes `key` from `key=`, and so does Bonjour —
    /// `NWTXTRecord.Entry.none` against `.empty`. Collapsing them would make a
    /// present-but-valueless key read as an empty string.
    @Test("An attribute with no value stays distinct from an empty one")
    func valuelessAttribute() throws {
        let record = try TXTRecord([
            TXTRecord.Entry(key: "flag", value: nil),
            TXTRecord.Entry(key: "empty", value: ""),
        ])
        #expect(record.avahiEntries == [Array("flag".utf8), Array("empty=".utf8)])

        let decoded = try TXTRecord(dnsSDWireFormat: record.dnsSDWireFormat)
        #expect(decoded.entry(for: "flag")?.value == nil)
        #expect(decoded.entry(for: "empty")?.value?.isEmpty == true)
        #expect(decoded == record)
    }

    /// The rules RFC 6763 §6.4 gives for a malformed entry: ignore it, do not
    /// reject the record. Structural corruption is a different matter.
    @Test("Entries the specification says to ignore are ignored")
    func ignoresWhatTheSpecificationIgnores() throws {
        var bytes = Data()
        bytes.append(0)  // A zero-length string.
        bytes.append(contentsOf: [2] + Array("=v".utf8))  // A key that is empty.
        bytes.append(contentsOf: [6] + Array("id=abc".utf8))

        let decoded = try TXTRecord(dnsSDWireFormat: bytes)
        #expect(decoded.entries.count == 1)
        #expect(decoded.entry(for: "id")?.stringValue == "abc")
    }

    @Test("A length octet that overruns the record throws")
    func refusesTruncatedRecords() {
        let truncated = Data([9] + Array("txtvers".utf8))
        #expect(throws: TXTRecordError.truncated) { try TXTRecord(dnsSDWireFormat: truncated) }
    }

    /// RFC 6763 §6.2 wants the whole record inside one packet.
    @Test("A record over the packet limit throws")
    func enforcesTheRecordLimit() throws {
        let value = String(repeating: "v", count: 250)
        let entries = try (0..<6).map { try TXTRecord.Entry(key: "k\($0)", value: value) }
        #expect(throws: TXTRecordError.self) { try TXTRecord(entries) }
        #expect(throws: Never.self) { try TXTRecord(Array(entries.prefix(5))) }
    }

    /// An avahi entry is an unbounded byte array, so unlike the DNS-SD wire
    /// form it can carry something too long to be a legal entry.
    @Test("An over-long avahi entry is refused on the way in")
    func refusesOverlongAvahiEntries() {
        let oversized = Array("k=".utf8) + Array(repeating: UInt8(ascii: "v"), count: 254)
        #expect(throws: TXTRecordError.self) { try TXTRecord(avahiEntries: [oversized]) }
    }

    /// The other half of what ``TXTRecord/init(received:)`` documents. A
    /// received entry still goes through the strict `Entry` initializer, so a
    /// key carrying a byte outside 0x20–0x7E rejects that peer's whole record
    /// rather than being dropped the way §6.4's own ignorable cases are. The
    /// invariant is what lets ``TXTRecord/dnsSDWireFormat`` write its length
    /// octet without a check.
    @Test("A received key that is not printable ASCII rejects the record")
    func refusesNonPrintableReceivedKeys() {
        // One five-byte entry: `k`, 0x01, `=`, `v`, `v`.
        let bytes = Data([5, 0x6B, 0x01, 0x3D, 0x76, 0x76])
        #expect(throws: TXTRecordError.self) { try TXTRecord(dnsSDWireFormat: bytes) }
        #expect(throws: TXTRecordError.self) {
            try TXTRecord(avahiEntries: [[0x6B, 0x01, 0x3D, 0x76, 0x76]])
        }
    }

    /// Bytes that are not UTF-8 stay bytes. A record is not required to be
    /// text, and lossily decoding a value would change what was advertised.
    @Test("A value that is not UTF-8 survives as bytes")
    func nonUTF8Value() throws {
        let entry = try TXTRecord.Entry(key: "k", value: [0xFF, 0xFE])
        let decoded = try TXTRecord(dnsSDWireFormat: TXTRecord([entry]).dnsSDWireFormat)
        #expect(decoded.entry(for: "k")?.value == [0xFF, 0xFE])
        #expect(decoded.entry(for: "k")?.stringValue == nil)
    }
}
