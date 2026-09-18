import Foundation
import SkrepkaIPC

@testable import SkrepkaLinuxUI

/// Documents the daemon could have sent, for the Settings window's tests.
enum SyncFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let macID = String(repeating: "ab", count: 32)
    static let deckID = String(repeating: "cd", count: 32)
    static let laptopID = String(repeating: "ef", count: 32)

    static func paired(
        _ id: String = macID,
        name: String? = "MacBook",
        linkState: String = "synced",
        isSighted: Bool = true,
        lastSyncedAt: Date? = now - 90,
        livePush: Bool = true,
        choice: String? = PeerDocument.LivePushChoiceName.followsPlatformDefault,
        reason: String? = PeerDocument.LivePushDefaultName.on
    ) -> PeerDocument {
        PeerDocument(
            deviceID: id,
            fingerprint: fingerprint(id),
            name: name,
            platform: "macos",
            isPaired: true,
            isSighted: isSighted,
            isAcceptingPairing: false,
            linkState: linkState,
            livePush: livePush,
            lastSyncedAt: lastSyncedAt,
            livePushChoice: choice,
            livePushDefault: reason
        )
    }

    static func nearby(
        _ id: String = deckID,
        name: String? = "Deck",
        isAccepting: Bool = true
    ) -> PeerDocument {
        PeerDocument(
            deviceID: id,
            fingerprint: fingerprint(id),
            name: name,
            platform: "linux",
            isPaired: false,
            isSighted: true,
            isAcceptingPairing: isAccepting,
            linkState: "not paired",
            livePush: false,
            lastSyncedAt: nil
        )
    }

    static func document(
        _ peers: [PeerDocument] = [],
        pairingPort: UInt16? = nil,
        localFingerprint: String = "1A2B-3C4D-5E6F-7A8B"
    ) -> PeersDocument {
        PeersDocument(
            localDeviceID: localFingerprint.isEmpty ? "" : String(repeating: "12", count: 32),
            localFingerprint: localFingerprint,
            localName: "steamdeck",
            peers: peers,
            pairingPort: pairingPort
        )
    }

    static func proposal(
        _ id: String = deckID,
        name: String? = "Deck",
        direction: String = PairingProposalDocument.Direction.incoming,
        expiresIn seconds: TimeInterval = 120
    ) -> PairingProposalDocument {
        PairingProposalDocument(
            deviceID: id,
            fingerprint: fingerprint(id),
            name: name,
            platform: "linux",
            shortAuthString: "A3F2-91BC-D4E7-0182",
            direction: direction,
            expiresAt: now + seconds
        )
    }

    static func fingerprint(_ id: String) -> String {
        String(id.prefix(8)).uppercased()
    }

    /// A model that has read `document` once.
    static func model(_ document: PeersDocument) -> SyncModel {
        SyncModel().applying(.refreshed(document), now: now).model
    }
}
