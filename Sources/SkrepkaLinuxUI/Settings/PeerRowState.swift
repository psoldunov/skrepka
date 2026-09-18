import Foundation
import SkrepkaIPC

/// One device in the Devices list, as the row draws it.
///
/// The same decisions the macOS row makes, from the daemon's document rather
/// than from a live `PeerLink`: one line under the name, chosen by what the
/// user most needs to know now, and the one decision they can take about it.
public struct PeerRowState: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// A device on the network and not paired.
        case pair(isEnabled: Bool)
        case unpair(isEnabled: Bool)
    }

    /// The per-device switch, for paired devices only.
    public struct LivePush: Sendable, Hashable {
        public let isOn: Bool
        public let isEnabled: Bool
        public let explanation: String
    }

    /// The device's full hex ID.
    public let id: String
    public let title: String
    public let subtitle: String
    public let platform: String
    public let action: Action
    public let livePush: LivePush?

    /// - Parameter canAct: Whether the window can send anything at all right
    ///   now — the daemon answered, sync is on, and no pairing is on screen.
    init(_ peer: PeerDocument, model: SyncModel, canAct: Bool, now: Date) {
        id = peer.deviceID
        title = peer.name ?? peer.fingerprint
        platform = SyncText.platform(peer.platform)
        subtitle = Self.subtitle(peer, now: now)
        if peer.isPaired {
            let unpairing = model.isInFlight(.unpair(deviceID: peer.deviceID))
            action = .unpair(isEnabled: canAct && !unpairing)
            livePush = Self.livePush(peer, model: model, canAct: canAct)
        } else {
            // Not accepting means the dial would be refused, so the button
            // says so by being disabled rather than by failing.
            action = .pair(isEnabled: canAct && peer.isAcceptingPairing)
            livePush = nil
        }
    }

    // MARK: - The line under the name

    /// A failure outranks everything; then being out of reach; then the last
    /// exchange. Only one, because a row that stacks all three is a row
    /// nobody reads.
    static func subtitle(_ peer: PeerDocument, now: Date) -> String {
        guard peer.isPaired else {
            return peer.isAcceptingPairing
                ? "On this network — \(peer.fingerprint)"
                : "Not accepting new pairings — \(peer.fingerprint)"
        }
        let failurePrefix = "failed: "
        if peer.linkState.hasPrefix(failurePrefix) {
            let reason = peer.linkState.dropFirst(failurePrefix.count)
            return "Could not connect: \(reason)"
        }
        if peer.linkState == "connecting" {
            return "Connecting…"
        }
        guard peer.isSighted else {
            return "Not on this network right now"
        }
        guard let last = peer.lastSyncedAt else {
            return "Paired — \(peer.fingerprint)"
        }
        return "Synced \(SyncText.ago(last, now: now))"
    }

    // MARK: - Live push

    private static func livePush(_ peer: PeerDocument, model: SyncModel, canAct: Bool) -> LivePush {
        // A switch the user just flipped keeps the position they gave it until
        // the daemon has answered, rather than snapping back on the next poll.
        let pending = model.inFlight.last { action in
            guard case .setLivePush(let deviceID, _) = action else { return false }
            return deviceID == peer.deviceID
        }
        let isOn: Bool
        if case .setLivePush(_, let wanted)? = pending {
            isOn = wanted
        } else {
            isOn = peer.livePush
        }
        guard let choice = peer.livePushChoice else {
            // A daemon from before interface version 2 has no member to set it.
            return LivePush(
                isOn: isOn,
                isEnabled: false,
                explanation: "This daemon is too old to change this here — update skrepkad."
            )
        }
        return LivePush(
            isOn: isOn,
            isEnabled: canAct && pending == nil,
            explanation: explanation(choice: choice, reason: peer.livePushDefault, isOn: isOn)
        )
    }

    /// The sentence design §11 requires beside the switch, so a switch that is
    /// off says why rather than looking broken.
    static func explanation(choice: String, reason: String?, isOn: Bool) -> String {
        let pushes = "What you copy here goes straight to this device's clipboard."
        guard choice == PeerDocument.LivePushChoiceName.followsPlatformDefault else {
            return isOn ? pushes : "Only history is shared with this device."
        }
        switch reason {
        case PeerDocument.LivePushDefaultName.offBetweenAppleDevices:
            return """
                Off by default — Universal Clipboard already does this between two \
                Apple devices. History is still shared.
                """
        case PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform:
            return """
                Off until this device connects and says what system it runs. \
                History is still shared.
                """
        default:
            return isOn ? pushes : "Off. History is still shared."
        }
    }
}
