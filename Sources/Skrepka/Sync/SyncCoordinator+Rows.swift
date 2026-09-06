import Foundation
import SkrepkaSync

/// What the Sync pane reads: the paired set and the browse results, folded into
/// one sorted list.
extension SyncCoordinator {
    /// Rebuilds ``peers`` from everything that feeds it.
    ///
    /// One projection recomputed on every change rather than four sources the
    /// view reads separately. The list is a handful of rows, so the cost is
    /// nothing, and a view that joined them itself would have to repeat the rule
    /// that a paired peer outranks a sighting of the same device.
    func refreshRows() {
        let paired = self.paired.values.map(row(forPaired:))
        let seen = sighted.values
            .filter { self.paired[$0.advertisement.deviceID] == nil }
            .map(row(forSighted:))
        peers = paired.sorted(by: Self.byName) + seen.sorted(by: Self.byName)
    }

    /// The peer's name for display: what it called itself inside the tunnel
    /// first, then what it advertised, then its fingerprint.
    ///
    /// In that order because that is the order of how much each is worth. The
    /// name from `hello` arrived inside a tunnel whose certificate is pinned;
    /// the advertised one arrived unauthenticated off the network; the
    /// fingerprint is derived here and cannot be claimed at all.
    func rowName(for deviceID: SyncDeviceID) -> String {
        if let name = progress[deviceID]?.name, !name.isEmpty { return name }
        if let name = paired[deviceID]?.deviceName, !name.isEmpty { return name }
        if let name = sighted[deviceID]?.advertisement.displayName, !name.isEmpty { return name }
        return deviceID.fingerprint
    }

    private func row(forPaired peer: PairedPeer) -> SyncPeerRow {
        let entry = progress[peer.deviceID] ?? PeerProgress()
        return SyncPeerRow(
            deviceID: peer.deviceID,
            name: rowName(for: peer.deviceID),
            // The platform proved inside the tunnel outranks the one recorded at
            // pairing, which came off an unauthenticated record.
            platform: entry.platform ?? peer.platform,
            trust: .paired(since: peer.pairedAt),
            link: isEnabled ? entry.link : .idle,
            lastSyncedAt: entry.lastSyncedAt,
            received: entry.received,
            pushed: entry.pushed,
            livePush: livePushSetting(for: peer.deviceID)
        )
    }

    private func row(forSighted sighting: SightedPeer) -> SyncPeerRow {
        let advertisement = sighting.advertisement
        return SyncPeerRow(
            deviceID: advertisement.deviceID,
            name: advertisement.displayName ?? sighting.peer.instanceName,
            platform: advertisement.platform,
            trust: .seen(isAcceptingPairing: advertisement.isAcceptingPairing),
            link: .idle,
            lastSyncedAt: nil,
            received: 0,
            pushed: 0,
            livePush: LivePushSetting(local: .macos, remote: advertisement.platform)
        )
    }

    /// Live push for one peer: design §3's default for the pair, plus whatever
    /// the user chose instead.
    func livePushSetting(for deviceID: SyncDeviceID) -> LivePushSetting {
        LivePushSetting(
            local: .macos,
            remote: progress[deviceID]?.platform ?? paired[deviceID]?.platform ?? .unknown,
            choice: livePushChoices[deviceID] ?? .followsPlatformDefault
        )
    }

    /// Ordered by name, then by identifier so two machines called the same thing
    /// do not swap places between refreshes.
    private static func byName(_ first: SyncPeerRow, _ second: SyncPeerRow) -> Bool {
        let ordering = first.name.localizedCaseInsensitiveCompare(second.name)
        guard ordering == .orderedSame else { return ordering == .orderedAscending }
        return first.deviceID < second.deviceID
    }
}
