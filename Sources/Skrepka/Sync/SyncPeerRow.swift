import Foundation
import SkrepkaSync

/// One device in the Sync settings pane: what it is, whether it is trusted,
/// whether it is reachable, and what has crossed.
///
/// A value type rebuilt on every change rather than an observable object per
/// peer. The list is small, SwiftUI diffs it by ``id``, and a struct cannot be
/// mutated out from under a row that is drawing.
struct SyncPeerRow: Identifiable, Sendable, Hashable {
    /// Whether the user has approved this device.
    enum Trust: Sendable, Hashable {
        /// Paired, and pinned. `since` is what the pairing recorded.
        case paired(since: Date)
        /// Seen on the network and never approved.
        ///
        /// `isAcceptingPairing` is the peer's own `pair=` key: a device that is
        /// not advertising a pairing port will refuse the dial, and saying so in
        /// the row is better than a button that fails.
        case seen(isAcceptingPairing: Bool)
    }

    /// What the outbound connection to this device is doing.
    enum Link: Sendable, Hashable {
        /// Nothing is being attempted — the peer is not paired, or sync is off.
        case idle
        case connecting
        case connected
        /// The last attempt ended. The link retries; this is what to show
        /// meanwhile.
        case failed(reason: String)
    }

    let deviceID: SyncDeviceID
    /// The peer's own name where one is known, falling back to its fingerprint.
    let name: String
    let platform: PeerPlatform
    let trust: Trust
    let link: Link
    /// When an index exchange with this peer last completed.
    let lastSyncedAt: Date?
    /// Items learned from this peer since the app launched.
    ///
    /// Since launch rather than for all time: a durable per-peer counter is a
    /// column and a migration for a number nobody acts on, and the question the
    /// row answers — "is this working" — is a question about now.
    let received: Int
    /// Live pushes written to this peer since the app launched.
    let pushed: Int
    let livePush: LivePushSetting

    var id: SyncDeviceID { deviceID }

    var isPaired: Bool {
        if case .paired = trust { return true }
        return false
    }

    /// The short form of the identifier, which is what a user compares against
    /// another screen.
    var fingerprint: String { deviceID.fingerprint }
}
