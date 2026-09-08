import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaCLI

/// What the peer list and the pairing prompt put on screen.
///
/// The pairing assertions are about safety rather than cosmetics: the short
/// authentication string and the instruction to compare it are the only thing
/// standing between a user and pairing with somebody else on the network, so a
/// render that loses either is a security regression and worth failing a build.
@Suite("CLI peers and pairing")
struct CLIPairingReportTests {
    private func stamp() throws -> Date {
        try #require(ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
    }

    private func peer(
        fingerprint: String,
        isPaired: Bool,
        isSighted: Bool = true,
        lastSyncedAt: Date? = nil
    ) -> PeerDocument {
        PeerDocument(
            deviceID: String(repeating: "a", count: 64),
            fingerprint: fingerprint,
            name: isPaired ? "Studio" : nil,
            platform: "macos",
            isPaired: isPaired,
            isSighted: isSighted,
            isAcceptingPairing: !isPaired,
            linkState: isPaired ? "synced" : "idle",
            livePush: false,
            lastSyncedAt: lastSyncedAt
        )
    }

    @Test("`peers` prints this device's own fingerprint first")
    func localIdentityLeads() throws {
        let document = PeersDocument(
            localDeviceID: String(repeating: "b", count: 64),
            localFingerprint: "ab-cd-ef",
            localName: "Steam Deck",
            peers: [],
            pairingPort: 5556
        )
        let text = PeersReport.text(document, timeZone: .gmt)
        #expect(text.hasPrefix("THIS DEVICE"))
        #expect(text.contains("  fingerprint  ab-cd-ef"))
        #expect(text.contains("accepting pairings on port 5556"))
        #expect(text.contains("none yet — run `skrepka pair`"))
        #expect(text.contains("nothing else in sight"))
    }

    @Test("a paired peer shows its link, and an unpaired one shows how to pair with it")
    func peerSections() throws {
        let document = PeersDocument(
            localDeviceID: String(repeating: "b", count: 64),
            localFingerprint: "ab-cd-ef",
            localName: "Steam Deck",
            peers: [
                peer(fingerprint: "11-22-33", isPaired: true, lastSyncedAt: try stamp()),
                peer(fingerprint: "44-55-66", isPaired: false),
            ],
            pairingPort: nil
        )
        let text = PeersReport.text(document, timeZone: .gmt)
        #expect(text.contains("  Studio  (11-22-33)  macos"))
        #expect(text.contains("    link        synced"))
        #expect(text.contains("    live push   off"))
        #expect(text.contains("    last sync   01-02 03:04"))
        #expect(text.contains("  unnamed  (44-55-66)  macos"))
        #expect(text.contains("`skrepka pair --peer 44-55-66`"))
        #expect(text.contains("not accepting pairings"))
    }

    @Test("the pairing prompt carries the words and the instruction to compare them")
    func pairingPromptShowsTheSAS() throws {
        let proposal = PairingProposalDocument(
            deviceID: String(repeating: "a", count: 64),
            fingerprint: "11-22-33",
            name: "Studio",
            platform: "macos",
            shortAuthString: "amber cactus violin",
            direction: PairingProposalDocument.Direction.incoming,
            expiresAt: try stamp()
        )
        let text = PairingReport.text(proposal, timeZone: .gmt)
        #expect(text.contains("amber cactus violin"))
        #expect(text.contains("must appear on the other device"))
        #expect(text.contains("answer no"))
        #expect(text.contains("Studio (macos) is asking to pair with this device."))
        #expect(text.contains("fingerprint  11-22-33"))
        #expect(text.contains("expires      01-02 03:04"))
    }

    @Test("a peer that has told us nothing about itself still gets a prompt")
    func outgoingPromptWithoutAName() throws {
        let proposal = PairingProposalDocument(
            deviceID: String(repeating: "a", count: 64),
            fingerprint: "11-22-33",
            name: nil,
            platform: "linux",
            shortAuthString: "amber cactus violin",
            direction: PairingProposalDocument.Direction.outgoing,
            expiresAt: try stamp()
        )
        let text = PairingReport.text(proposal, timeZone: .gmt)
        #expect(text.contains("Pairing with an unnamed device (linux)."))
        #expect(text.contains("amber cactus violin"))
    }
}
