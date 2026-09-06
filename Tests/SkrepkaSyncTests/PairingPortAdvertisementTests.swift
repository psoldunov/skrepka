import Foundation
import Testing

@testable import SkrepkaSync

/// The `pair=` key: the port a device that has never paired with this one may
/// dial, and the fact that it is absent when there is no such port.
///
/// A second port because the two listeners cannot be one. The advertised sync
/// port is pinned — its TLS callback accepts only certificates the user has
/// already approved — and pairing is by definition a connection from a device
/// with nothing pinned. One listener under both policies would accept any
/// well-formed leaf on the port that also serves history, which is the failure
/// `PinPolicy` exists to prevent.
@Suite("Pairing port advertisement")
struct PairingPortAdvertisementTests {
    private static func descriptor(pairingPort: UInt16?) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: "desktop",
            port: 7311,
            deviceID: SyncFixtures.deviceA,
            platform: .macos,
            pairingPort: pairingPort
        )
    }

    @Test("A device willing to pair advertises the port to dial")
    func advertisesThePairingPort() throws {
        let record = try Self.descriptor(pairingPort: 7312).txtRecord()
        #expect(record.entry(for: "pair")?.stringValue == "7312")

        let advertisement = try PeerAdvertisement(txtRecord: record)
        #expect(advertisement.pairingPort == 7312)
        #expect(advertisement.isAcceptingPairing)
        #expect(advertisement.unrecognisedKeys.isEmpty)
    }

    /// Absent is a fact rather than a gap: the listener runs only while the user
    /// has asked to pair, so an omitted key says "this device is not accepting
    /// new pairings", which a peer can show instead of offering a button that
    /// fails.
    @Test("A device not accepting pairings leaves the key out entirely")
    func omitsThePairingPortWhenClosed() throws {
        let record = try Self.descriptor(pairingPort: nil).txtRecord()
        #expect(record.entry(for: "pair") == nil)

        let advertisement = try PeerAdvertisement(txtRecord: record)
        #expect(advertisement.pairingPort == nil)
        #expect(!advertisement.isAcceptingPairing)
    }

    /// Present and unparseable is not the same as absent. Reading it as "not
    /// pairing" would hide a broken peer behind an ordinary-looking state.
    @Test("A pair key that is not a port is refused", arguments: ["", "0", "-1", "70000", "soon"])
    func refusesAMalformedPairingPort(value: String) throws {
        let record = try TXTRecord([
            try TXTRecord.Entry(key: "txtvers", value: "1"),
            try TXTRecord.Entry(key: "id", value: SyncFixtures.deviceA.hex),
            try TXTRecord.Entry(key: "proto", value: "1"),
            try TXTRecord.Entry(key: "plat", value: "macos"),
            try TXTRecord.Entry(key: "pair", value: value),
        ])
        #expect(throws: AdvertisementError.self) {
            _ = try PeerAdvertisement(txtRecord: record)
        }
    }

    /// The key is one this build writes, so it must not also be reported as one
    /// this build has never heard of.
    @Test("The pairing port is a known key")
    func thePairingPortIsAKnownKey() {
        #expect(ServiceDescriptor.Key.all.contains(ServiceDescriptor.Key.pairingPort))
    }
}
