import SkrepkaIPC

/// The daemon members the Settings window calls.
///
/// A protocol rather than `DaemonProxy` directly so ``DaemonLink`` can be
/// tested against a fake that decides when each call returns — the property
/// worth testing is the order calls happen in, which a live daemon cannot be
/// made to show on demand.
public protocol SyncDaemon: Sendable {
    func peers() async throws -> PeersDocument
    func openPairing(seconds: UInt32) async throws -> PairingWindowDocument
    func closePairing() async throws -> ActionDocument
    /// Dials a device to pair. Waits as long as the daemon's own dial may take.
    func pairWith(deviceID: String) async throws -> PairingProposalDocument
    func confirmPairing(deviceID: String, accept: Bool) async throws -> ActionDocument
    func unpair(fingerprint: String) async throws -> ActionDocument
    func setLivePush(device: String, choice: String) async throws -> ActionDocument
    func syncNow() async throws -> ActionDocument
    /// Every pairing a peer starts against this device, until the stream is
    /// dropped or the connection ends.
    func pairingRequests() async throws -> AsyncStream<PairingProposalDocument>
}

extension DaemonProxy: SyncDaemon {
    public func pairWith(deviceID: String) async throws -> PairingProposalDocument {
        try await withTimeout(SkrepkaBus.pairingCallTimeout).pair(with: deviceID)
    }
}
