import Foundation
import Testing

@testable import SkrepkaSync

/// Reading a record that came off the network from a device this build has
/// never met.
@Suite("Peer advertisement")
struct PeerAdvertisementTests {
    static func record(_ overrides: [String: String?] = [:]) throws -> TXTRecord {
        var pairs: [(String, String)] = [
            ("txtvers", "1"),
            ("id", SyncFixtures.deviceB.hex),
            ("name", "desktop"),
            ("proto", "1"),
            ("plat", "linux"),
        ]
        for (key, value) in overrides {
            pairs.removeAll { $0.0 == key }
            if let value { pairs.append((key, value)) }
        }
        return try TXTRecord(pairs.map { try TXTRecord.Entry(key: $0.0, value: $0.1) })
    }

    @Test("A well-formed record reads")
    func readsAWellFormedRecord() throws {
        let advertisement = try PeerAdvertisement(txtRecord: Self.record())
        #expect(advertisement.deviceID == SyncFixtures.deviceB)
        #expect(advertisement.displayName == "desktop")
        #expect(advertisement.platform == .linux)
        #expect(advertisement.protocolVersion == .current)
        #expect(advertisement.speaksAKnownProtocolVersion)
    }

    /// The forward-compatibility rule `FrameError.unknownMessageType` follows,
    /// applied at discovery: a peer speaking a newer protocol is still a peer,
    /// and dropping it at browse time turns a negotiable difference into a
    /// machine that never appears.
    @Test("A protocol version from the future is surfaced, not dropped")
    func surfacesAnUnknownProtocolVersion() throws {
        let advertisement = try PeerAdvertisement(txtRecord: Self.record(["proto": "99"]))
        #expect(advertisement.protocolVersion == ProtocolVersion(rawValue: 99))
        #expect(advertisement.speaksAKnownProtocolVersion == false)
        #expect(advertisement.deviceID == SyncFixtures.deviceB)
    }

    /// Same rule for keys: a peer built later may advertise more than this
    /// build knows about, and the extras are worth naming rather than
    /// refusing over.
    @Test("Keys this build does not know are reported rather than refused")
    func reportsUnrecognisedKeys() throws {
        let advertisement = try PeerAdvertisement(
            txtRecord: Self.record(["quic": "1", "Region": "eu"]))
        #expect(advertisement.unrecognisedKeys == ["quic", "region"])
        #expect(advertisement.deviceID == SyncFixtures.deviceB)
    }

    /// `txtvers` is the grammar's version, not the protocol's. A value this
    /// build does not know means the keys underneath cannot be trusted to mean
    /// what they usually mean, which is why this one *is* fatal to the read.
    @Test("An unknown txtvers is refused where an unknown proto is not")
    func refusesAnUnknownRecordVersion() throws {
        #expect(throws: AdvertisementError.unsupportedRecordVersion("2")) {
            try PeerAdvertisement(txtRecord: Self.record(["txtvers": "2"]))
        }
        #expect(throws: AdvertisementError.missingKey("txtvers")) {
            try PeerAdvertisement(txtRecord: Self.record(["txtvers": nil]))
        }
    }

    /// Named failures, not a silently skipped peer. "Why can I not see my
    /// other machine" is the bug report these prevent.
    @Test("A record missing a required key names the key")
    func namesAMissingKey() throws {
        #expect(throws: AdvertisementError.missingKey("id")) {
            try PeerAdvertisement(txtRecord: Self.record(["id": nil]))
        }
        #expect(throws: AdvertisementError.missingKey("proto")) {
            try PeerAdvertisement(txtRecord: Self.record(["proto": nil]))
        }
    }

    @Test("A malformed identifier is refused rather than normalised")
    func refusesAMalformedIdentifier() throws {
        for hex in ["", "abc", SyncFixtures.deviceB.hex.uppercased()] {
            #expect(throws: AdvertisementError.self) {
                try PeerAdvertisement(txtRecord: Self.record(["id": hex]))
            }
        }
    }

    @Test("A protocol version that is not a positive integer is refused")
    func refusesAMalformedProtocolVersion() throws {
        for value in ["", "v1", "0", "-1", "1.0"] {
            #expect(throws: AdvertisementError.self) {
                try PeerAdvertisement(txtRecord: Self.record(["proto": value]))
            }
        }
    }

    /// One rule for absent and unrecognised, because there is nothing to tell
    /// them apart — and it is ``PeerPlatform``'s existing rule, not a second
    /// one invented here.
    @Test("An absent or unrecognised platform is unknown, and live push stays off")
    func platformFallsBackToUnknown() throws {
        let absent = try PeerAdvertisement(txtRecord: Self.record(["plat": nil]))
        let unrecognised = try PeerAdvertisement(txtRecord: Self.record(["plat": "haiku"]))

        #expect(absent.platform == .unknown)
        #expect(unrecognised.platform == .unknown)
        #expect(
            PeerPlatform.livePushDefaultsOn(local: .macos, remote: absent.platform) == false)
    }

    /// `name` is a label. A peer without one is still connectable, and the
    /// caller falls back to the DNS-SD instance name.
    @Test("An absent display name is nil rather than an error")
    func displayNameIsOptional() throws {
        #expect(try PeerAdvertisement(txtRecord: Self.record(["name": nil])).displayName == nil)
    }

    /// A key advertised with no `=` at all reads as absent, because none of
    /// these keys means anything without a value.
    @Test("A required key present with no value reads as missing")
    func valuelessRequiredKey() throws {
        let record = try TXTRecord([
            TXTRecord.Entry(key: "txtvers", value: "1"),
            TXTRecord.Entry(key: "id", value: nil),
            TXTRecord.Entry(key: "proto", value: "1"),
        ])
        #expect(throws: AdvertisementError.missingKey("id")) {
            try PeerAdvertisement(txtRecord: record)
        }
    }

    @Test("A value that is not UTF-8 names the key it came from")
    func refusesNonUTF8Values() throws {
        let record = try TXTRecord([
            TXTRecord.Entry(key: "txtvers", value: "1"),
            TXTRecord.Entry(key: "id", value: [0xFF, 0xFE]),
            TXTRecord.Entry(key: "proto", value: "1"),
        ])
        #expect(throws: AdvertisementError.malformedValue(key: "id", reason: "not UTF-8")) {
            try PeerAdvertisement(txtRecord: record)
        }
    }

    /// Bytes that are not a TXT record at all become one named error rather
    /// than leaking the codec's own error type upward.
    @Test("Bytes that are not a record report a malformed record")
    func refusesCorruptBytes() {
        #expect(throws: AdvertisementError.self) {
            try PeerAdvertisement(dnsSDWireFormat: Data([9] + Array("txtvers".utf8)))
        }
    }
}
