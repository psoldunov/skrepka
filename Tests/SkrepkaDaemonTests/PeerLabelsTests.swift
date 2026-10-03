import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// How `skrepka doctor` and the Status pane name a paired device: by the name
/// the Sync pane shows for it, not by a fingerprint that tells a person nothing.
@Suite("Peer labels")
struct PeerLabelsTests {
    private let mac = Self.paired("a paired Mac", named: "BigMac")
    private let deck = Self.paired("a paired Deck", named: "steamdeck")

    private static func paired(_ certificate: String, named name: String) -> PairedPeer {
        PairedPeer(
            certificateDER: Data(certificate.utf8),
            deviceName: name,
            platform: .macos,
            pairedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private static func progress(named name: String?) -> PeerProgress {
        var entry = PeerProgress()
        entry.name = name
        return entry
    }

    private func byID(_ peers: PairedPeer...) -> [SyncDeviceID: PairedPeer] {
        Dictionary(uniqueKeysWithValues: peers.map { ($0.deviceID, $0) })
    }

    /// The case from the Status pane: a peer that is asleep has never sent
    /// `hello` in this process, so the name it was paired under is all there is.
    @Test("A peer off the network goes by the name it was paired under")
    func usesThePairedName() {
        let labels = PeerLabels.labels(for: [mac.deviceID], progress: [:], paired: byID(mac))
        #expect(labels == ["BigMac"])
    }

    @Test("The name from hello outranks the one from pairing")
    func prefersTheHelloName() {
        let labels = PeerLabels.labels(
            for: [mac.deviceID],
            progress: [mac.deviceID: Self.progress(named: "Philipp's MacBook")],
            paired: byID(mac)
        )
        #expect(labels == ["Philipp's MacBook"])
    }

    @Test("A device with no name at all falls back to its fingerprint")
    func fallsBackToTheFingerprint() {
        let nameless = Self.paired("a nameless peer", named: "")
        let unknown = SyncDeviceID(certificateDER: Data("a peer the store lost".utf8))
        let labels = PeerLabels.labels(
            for: [nameless.deviceID, unknown], progress: [:], paired: byID(nameless))
        #expect(labels == [nameless.deviceID.fingerprint, unknown.fingerprint].sorted())
    }

    /// A peer chose its own name; a pinned one still goes through the same
    /// sanitising the Sync pane's list does before it lands in a sentence.
    @Test("A name is one line of printable text")
    func sanitisesTheName() {
        let rude = Self.paired("a rude peer", named: "Evil\u{1B}[2J\nMac")
        let labels = PeerLabels.labels(for: [rude.deviceID], progress: [:], paired: byID(rude))
        #expect(labels == ["Evil[2J Mac"])
    }

    /// Two Macs both called "MacBook Pro" would otherwise read as one device
    /// listed twice.
    @Test("Devices that share a name are told apart by fingerprint")
    func disambiguatesDuplicates() {
        let twin = Self.paired("the other Mac", named: "BigMac")
        let labels = PeerLabels.labels(
            for: [mac.deviceID, twin.deviceID, deck.deviceID],
            progress: [:],
            paired: byID(mac, twin, deck)
        )
        #expect(
            labels
                == [
                    "BigMac (\(mac.deviceID.fingerprint))",
                    "BigMac (\(twin.deviceID.fingerprint))",
                    "steamdeck",
                ].sorted())
    }

    @Test("The list is sorted, so the sentence does not reorder between reads")
    func sortsTheLabels() {
        let labels = PeerLabels.labels(
            for: [deck.deviceID, mac.deviceID], progress: [:], paired: byID(mac, deck))
        #expect(labels == ["BigMac", "steamdeck"])
    }
}
