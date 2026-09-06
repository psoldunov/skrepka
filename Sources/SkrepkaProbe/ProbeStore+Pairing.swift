import Foundation
import SkrepkaSync

/// The paired-peer half of ``ProbeStore``, mirroring `HistoryStore+Pairing`
/// method for method.
///
/// Split from the history for the same reason it is split on the real stores:
/// the peer record is pinning material and the clipping is content, and only one
/// of the two is a secret worth thinking about.
extension ProbeStore: PairedDeviceStoring {
    public func pairedPeers() -> [PairedPeer] {
        storedPeers.values.compactMap(Self.peer(from:)).sorted { $0.pairedAt < $1.pairedAt }
    }

    public func pairedPeer(_ deviceID: SyncDeviceID) -> PairedPeer? {
        storedPeers[deviceID.hex].flatMap(Self.peer(from:))
    }

    /// Inserts or replaces the record, leaving the two per-peer facts beside it
    /// alone.
    ///
    /// Re-pairing must reset neither the anti-downgrade mark nor the live-push
    /// choice: forcing one re-pair would otherwise be enough to erase the first,
    /// and silently re-enable the second.
    public func savePairedPeer(_ peer: PairedPeer) throws {
        let held = storedPeers[peer.deviceID.hex]
        storedPeers[peer.deviceID.hex] = StoredPeer(
            certificateDER: peer.certificateDER,
            deviceName: peer.deviceName,
            platform: peer.platform.rawValue,
            pairedAt: peer.pairedAt,
            highestProtocolSeen: held?.highestProtocolSeen,
            livePushChoice: held?.livePushChoice
        )
        try persist()
    }

    public func forgetPairedPeer(_ deviceID: SyncDeviceID) throws {
        storedPeers[deviceID.hex] = nil
        try persist()
    }

    public func highestProtocolVersion(for deviceID: SyncDeviceID) -> ProtocolVersion? {
        storedPeers[deviceID.hex]?.highestProtocolSeen.map(ProtocolVersion.init(rawValue:))
    }

    /// Raises the mark when `version` is higher, and never lowers it.
    public func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) throws {
        guard var peer = storedPeers[deviceID.hex] else { return }
        guard (peer.highestProtocolSeen ?? Int.min) < version.rawValue else { return }
        peer.highestProtocolSeen = version.rawValue
        storedPeers[deviceID.hex] = peer
        try persist()
    }

    public func livePushChoice(for deviceID: SyncDeviceID) -> LivePushChoice {
        LivePushChoice(storedValue: storedPeers[deviceID.hex]?.livePushChoice)
    }

    public func setLivePushChoice(_ choice: LivePushChoice, for deviceID: SyncDeviceID) throws {
        guard var peer = storedPeers[deviceID.hex] else { return }
        peer.livePushChoice = choice.storedValue
        storedPeers[deviceID.hex] = peer
        try persist()
    }

    /// A row whose stored identifier disagrees with its stored certificate names
    /// no peer, and there is no repair for that: substituting either half would
    /// authenticate a device on the strength of the other.
    private static func peer(from stored: StoredPeer) -> PairedPeer? {
        PairedPeer(
            certificateDER: stored.certificateDER,
            deviceName: stored.deviceName,
            platform: PeerPlatform(wireValue: stored.platform),
            pairedAt: stored.pairedAt
        )
    }
}
