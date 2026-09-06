import Foundation

/// A ``TrustStore`` that keeps everything in memory and forgets it on exit.
///
/// Ships in the target rather than in the test bundle because it is also what
/// the Linux daemon uses before Phase 6 gives it a file to write to, and what a
/// `--ephemeral` run would use. An actor, so the two connections of a loopback
/// test can share one without a lock.
public actor InMemoryTrustStore: TrustStore {
    private var identity: DeviceCertificate?
    private var peers: [SyncDeviceID: PairedPeer] = [:]
    private var protocolMarks: [SyncDeviceID: ProtocolVersion] = [:]
    private var livePushChoices: [SyncDeviceID: LivePushChoice] = [:]

    /// - Parameter identity: an identity to start with. Passing one is what
    ///   lets a test use a fixture certificate instead of paying for key
    ///   generation; passing nil generates on first use, like a real store.
    public init(identity: DeviceCertificate? = nil) {
        self.identity = identity
    }

    public func localIdentity() throws -> DeviceCertificate {
        if let identity { return identity }
        let generated = try DeviceCertificate.generate()
        identity = generated
        return generated
    }

    public func pairedPeers() -> [PairedPeer] {
        peers.values.sorted { $0.deviceID < $1.deviceID }
    }

    public func pairedPeer(_ deviceID: SyncDeviceID) -> PairedPeer? {
        peers[deviceID]
    }

    public func savePairedPeer(_ peer: PairedPeer) {
        peers[peer.deviceID] = peer
    }

    public func forgetPairedPeer(_ deviceID: SyncDeviceID) {
        peers[deviceID] = nil
        protocolMarks[deviceID] = nil
        livePushChoices[deviceID] = nil
    }

    public func highestProtocolVersion(for deviceID: SyncDeviceID) -> ProtocolVersion? {
        protocolMarks[deviceID]
    }

    public func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) {
        protocolMarks[deviceID] = max(protocolMarks[deviceID] ?? version, version)
    }

    public func livePushChoice(for deviceID: SyncDeviceID) -> LivePushChoice {
        livePushChoices[deviceID] ?? .followsPlatformDefault
    }

    /// Does nothing for a device that is not paired, the same way
    /// ``recordProtocolVersion(_:for:)`` does — the persistent stores have no
    /// row to write on, and a fake that accepted the write would let a test
    /// pass against a contract they cannot meet.
    public func setLivePushChoice(_ choice: LivePushChoice, for deviceID: SyncDeviceID) {
        guard peers[deviceID] != nil else { return }
        livePushChoices[deviceID] = choice == .followsPlatformDefault ? nil : choice
    }
}
