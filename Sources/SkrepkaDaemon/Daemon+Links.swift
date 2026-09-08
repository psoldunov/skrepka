import Foundation
import Logging
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

/// The paired-peer links the browse feeds.
///
/// Split from `Daemon+Discovery.swift` at the 300-line ceiling
/// `swift-conventions.md` sets. The seam is the one the file already had: above
/// it is what avahi tells this daemon about the network, below it is what the
/// daemon does with a peer once it is trusted, and the only thing crossing is
/// ``Daemon/reconcileLinks()`` being called from every browse event.
extension Daemon {
    /// One link per paired peer, started, stopped and left alone as the paired
    /// set changes.
    /// A read that fails stops every link, because an empty answer and a failed
    /// one were the same value here. So the failure is reported and the links
    /// are left exactly as they are — a busy store must not un-pair a machine.
    func reconcileLinks() async {
        guard !isStopping, let runtime else { return }
        let peers: [PairedPeer]
        do {
            peers = try await trust.pairedPeers()
        } catch {
            logger.error(
                "could not read the paired devices; leaving the links alone",
                metadata: ["error": .string(String(describing: error))]
            )
            return
        }
        let wanted = Set(peers.map(\.deviceID))

        for deviceID in links.keys where !wanted.contains(deviceID) {
            let link = links.removeValue(forKey: deviceID)
            progress[deviceID] = nil
            await link?.stop()
        }
        for deviceID in wanted where links[deviceID] == nil {
            links[deviceID] = makeLink(to: deviceID, runtime: runtime)
            progress[deviceID] = PeerProgress()
        }
        // Starting a link that is already running does nothing, so a browse
        // event that re-announces a peer costs one call per peer and no state.
        for link in links.values { await link.start() }
    }

    private func makeLink(to deviceID: SyncDeviceID, runtime: SyncRuntime) -> PeerLink {
        PeerLink(
            peerDeviceID: deviceID,
            runtime: runtime,
            resolve: { [weak self] in
                guard let self else {
                    throw DiscoveryError.resolutionFailed(
                        peer: deviceID.fingerprint, reason: "the daemon has stopped")
                }
                return try await self.resolve(deviceID)
            },
            report: { [weak self] deviceID, event in
                await self?.apply(event, to: deviceID)
            }
        )
    }

    /// A paired peer's current address.
    ///
    /// Resolved fresh on every attempt rather than cached: a peer's address
    /// outlives neither sleep nor a network change, which is why
    /// `PeerDiscovery.resolve` says to call it immediately before connecting.
    func resolve(_ deviceID: SyncDeviceID) async throws -> ResolvedPeer {
        guard let discovery, let sighting = sighted[deviceID] else {
            throw DiscoveryError.resolutionFailed(
                peer: deviceID.fingerprint, reason: "not on the network")
        }
        return try await discovery.resolve(sighting.peer)
    }

    func apply(_ event: PeerLinkEvent, to deviceID: SyncDeviceID) {
        var entry = progress[deviceID] ?? PeerProgress()
        switch event {
        case .connecting:
            entry.state = "connecting"
        case .connected(let name, let platform):
            entry.state = "connected"
            entry.name = name
            entry.platform = platform
        case .synced(let learned, let at):
            entry.state = learned > 0 ? "synced, learned \(learned)" : "synced"
            entry.lastSyncedAt = at
        case .pushed:
            entry.state = "pushed"
        case .failed(let reason):
            // The one branch carrying free text, and it is a TLS or protocol
            // error whose wording a peer can influence. It lands in the same
            // column as `PeerDocument.name`, which is sanitised for the same
            // reason, so it is bounded and stripped the same way.
            entry.state = "failed: " + SafeText.oneLine(reason, limit: SafeText.nameLimit)
        }
        progress[deviceID] = entry
    }
}
