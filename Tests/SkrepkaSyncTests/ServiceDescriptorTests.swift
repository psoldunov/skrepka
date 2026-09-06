import Foundation
import Testing

@testable import SkrepkaSync

/// What this device puts on the wire for other devices to find.
@Suite("Service descriptor")
struct ServiceDescriptorTests {
    static func descriptor(
        name: String = "Работа",
        port: UInt16 = 7011,
        device: SyncDeviceID = SyncFixtures.deviceA,
        platform: PeerPlatform = .macos,
        protocolVersion: ProtocolVersion = .current
    ) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: name,
            port: port,
            deviceID: device,
            platform: platform,
            protocolVersion: protocolVersion
        )
    }

    /// Design §9's record, key by key, minus the `fp=` Phase 1 folded away.
    @Test("The record carries exactly the keys design §9 specifies")
    func recordContents() throws {
        let record = try Self.descriptor().txtRecord()

        #expect(record.entries.map(\.key) == ["txtvers", "id", "name", "proto", "plat"])
        #expect(record.entry(for: "txtvers")?.stringValue == "1")
        #expect(record.entry(for: "id")?.stringValue == SyncFixtures.deviceA.hex)
        #expect(record.entry(for: "name")?.stringValue == "Работа")
        #expect(record.entry(for: "proto")?.stringValue == "1")
        #expect(record.entry(for: "plat")?.stringValue == "macos")
    }

    /// `fp=` was a second identity for one device. ``SyncDeviceID`` is the
    /// SHA-256 of the certificate, so the fingerprint is a prefix of `id=` and
    /// two fields that could disagree became one that cannot.
    @Test("There is no fp key, and the fingerprint is a prefix of the identifier")
    func noSeparateFingerprint() throws {
        let record = try Self.descriptor().txtRecord()
        #expect(record.entry(for: "fp") == nil)

        let identifier = try #require(record.entry(for: "id")?.stringValue)
        #expect(identifier.hasPrefix(SyncFixtures.deviceA.fingerprint))
    }

    /// Every value is bounded by construction, so the record fits comfortably
    /// inside both the per-entry and the whole-record limits.
    @Test("Every entry is inside the 255-byte limit")
    func entriesFitTheLimit() throws {
        let record = try Self.descriptor(name: String(repeating: "я", count: 200)).txtRecord()
        for entry in record.entries {
            #expect(entry.rawBytes.count <= TXTRecord.maximumEntryBytes)
        }
        #expect(record.dnsSDWireFormat.count <= TXTRecord.maximumRecordBytes)
    }

    /// RFC 6763 §4.1.1 makes the instance name one DNS label, so 63 octets is
    /// the ceiling. Clamped rather than refused: the name is a label, and a Mac
    /// with a long name should still be findable.
    @Test("A long display name is clamped on a character boundary")
    func clampsTheDisplayName() {
        let clamped = Self.descriptor(name: String(repeating: "я", count: 100)).displayName
        #expect(clamped.utf8.count <= ServiceDescriptor.maximumDisplayNameBytes)
        // 63 bytes is not a whole number of two-byte characters, so a clamp
        // that counted bytes alone would cut one in half.
        #expect(clamped.count == 31)
        #expect(clamped == String(repeating: "я", count: 31))

        let short = Self.descriptor(name: "mac").displayName
        #expect(short == "mac")
    }

    /// An empty name is how a caller says "let the responder choose", which on
    /// macOS means the computer's own name. It must survive as empty on the
    /// descriptor, and it must leave `name=` out of the record: `name=` with an
    /// empty value is a name, and it would shadow the instance name the
    /// responder chose.
    @Test("An empty display name leaves the name key out of the record")
    func emptyDisplayName() throws {
        let descriptor = Self.descriptor(name: "")
        #expect(descriptor.displayName.isEmpty)

        let record = try descriptor.txtRecord()
        #expect(record.entry(for: "name") == nil)
        #expect(record.entries.map(\.key) == ["txtvers", "id", "proto", "plat"])
    }

    /// The consequence the previous test exists for: a reader of that record
    /// gets `nil` and can fall back to the DNS-SD instance name, which is what
    /// ``PeerAdvertisement/displayName`` documents.
    @Test("A record with no name key reads back as no display name")
    func emptyDisplayNameReadsAsNil() throws {
        let advertisement = try PeerAdvertisement(
            dnsSDWireFormat: Self.descriptor(name: "").txtRecord().dnsSDWireFormat)
        #expect(advertisement.displayName == nil)
        #expect(advertisement.unrecognisedKeys.isEmpty)
    }

    /// The whole point of the record: what one device advertises is what the
    /// other reads back.
    @Test("A descriptor round-trips through the wire form into an advertisement")
    func roundTripsIntoAnAdvertisement() throws {
        let descriptor = Self.descriptor(name: "desktop", device: SyncFixtures.deviceB, platform: .linux)
        let advertisement = try PeerAdvertisement(
            dnsSDWireFormat: descriptor.txtRecord().dnsSDWireFormat)

        #expect(advertisement.deviceID == SyncFixtures.deviceB)
        #expect(advertisement.displayName == "desktop")
        #expect(advertisement.platform == .linux)
        #expect(advertisement.protocolVersion == .current)
        #expect(advertisement.unrecognisedKeys.isEmpty)
        #expect(advertisement.fingerprint == SyncFixtures.deviceB.fingerprint)
    }

    /// Design §9: `_skrepka._tcp`, whose Service Name is seven characters,
    /// inside the fifteen RFC 6763 §7.2 allows.
    @Test("The service type is the one design §9 registered")
    func serviceType() {
        #expect(ServiceDescriptor.serviceType == "_skrepka._tcp")
        let serviceName = ServiceDescriptor.serviceType.split(separator: ".")[0].dropFirst()
        #expect(serviceName.count <= 15)
    }
}
