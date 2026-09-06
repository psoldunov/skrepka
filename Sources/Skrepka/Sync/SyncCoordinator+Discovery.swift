import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// The finding-and-being-found half of ``SyncCoordinator``, and the links it
/// keeps up as a result.
extension SyncCoordinator {
    // MARK: - Advertising and browsing

    func startDiscovery(runtime: SyncRuntime) async throws {
        let discovery = BonjourDiscovery()
        self.discovery = discovery
        try await discovery.startAdvertising(descriptor(for: runtime))
        try await watchBrowse(discovery)
    }

    /// Re-publishes the record, which is how a new listening port or an opened
    /// pairing window reaches the network.
    ///
    /// Stopped and started rather than amended: ``PeerDiscovery`` refuses to
    /// replace a live advertisement, because one device publishing two records
    /// appears twice.
    func republishAdvertisement() async throws {
        guard let discovery, let runtime, syncServer != nil else { return }
        await discovery.stopAdvertising()
        try await discovery.startAdvertising(descriptor(for: runtime))
    }

    private func descriptor(for runtime: SyncRuntime) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: displayName,
            port: UInt16(syncServer?.port ?? 0),
            deviceID: runtime.deviceID,
            platform: runtime.platform,
            // Advertised only while the window is open, so its absence tells a
            // peer this device will refuse a pairing dial rather than leaving it
            // to find out by being disconnected.
            pairingPort: pairingServer.map { UInt16($0.port) }
        )
    }

    /// Follows the browse for as long as sync is running.
    ///
    /// A failed browse is terminal — `NWBrowser` says so — so it is reported
    /// rather than retried in place. Everything else is a change to
    /// ``sighted``, and every change re-reconciles the links, because a paired
    /// peer appearing is exactly the moment to dial it.
    private func watchBrowse(_ discovery: BonjourDiscovery) async throws {
        let events = try await discovery.startBrowsing()
        browseTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: DiscoveryEvent) {
        switch event {
        case .appeared(let peer), .changed(let peer):
            record(peer)
        case .disappeared(let peer):
            forget(peer)
        case .ready:
            errorMessage = nil
        case .stalled(let error):
            errorMessage = Self.browseMessage(error)
        case .failed(let error):
            errorMessage = Self.browseMessage(error)
        }
        reconcileLinks()
        refreshRows()
    }

    /// A browse result is only useful once its record has been read: everything
    /// downstream keys on ``PeerAdvertisement/deviceID``, and a record that will
    /// not parse names no device.
    ///
    /// A peer whose record is unreadable is dropped from the list rather than
    /// shown as a nameless row, and the reason is logged. It is the one case
    /// where the state ``DiscoveredPeer/AdvertisementState/unreadable`` exists
    /// to preserve cannot be surfaced, because there is no identifier to file it
    /// under.
    private func record(_ peer: DiscoveredPeer) {
        switch peer.advertisement {
        case .read(let advertisement):
            guard advertisement.deviceID != localDeviceID else { return }
            sighted[advertisement.deviceID] = SightedPeer(peer: peer, advertisement: advertisement)
        case .unread:
            // `NWBrowser` is asked for TXT records, so this does not happen on
            // macOS. Resolving to fill it in would be a round trip per browse
            // event; the record arrives on the next `changed`.
            break
        case .unreadable(let error):
            SkrepkaLog.sync.notice(
                """
                Ignoring \(peer.instanceName, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """
            )
        }
    }

    private func forget(_ peer: DiscoveredPeer) {
        guard case .read(let advertisement) = peer.advertisement else { return }
        sighted[advertisement.deviceID] = nil
    }

    private static func browseMessage(_ error: DiscoveryError) -> String {
        """
        Skrepka cannot see the local network. Allow it in System Settings ▸ \
        Privacy & Security ▸ Local Network. (\(String(describing: error)))
        """
    }

    // MARK: - Links

    /// Starts a link for every paired peer and stops the ones that no longer
    /// belong.
    ///
    /// Idempotent, and called from every path that changes either set —
    /// ``PeerLink/start()`` on a running link does nothing, so a browse event
    /// that re-announces a peer costs nothing.
    func reconcileLinks() {
        guard let runtime else { return }
        for deviceID in links.keys where paired[deviceID] == nil {
            let link = links.removeValue(forKey: deviceID)
            progress[deviceID] = nil
            Task { await link?.stop() }
        }
        for deviceID in paired.keys where links[deviceID] == nil {
            links[deviceID] = makeLink(to: deviceID, runtime: runtime)
        }
        for link in links.values {
            Task { await link.start() }
        }
    }

    private func makeLink(to deviceID: SyncDeviceID, runtime: SyncRuntime) -> PeerLink {
        PeerLink(
            peerDeviceID: deviceID,
            runtime: runtime,
            resolve: { [weak self] in
                guard let self else {
                    throw DiscoveryError.resolutionFailed(
                        peer: deviceID.fingerprint,
                        reason: "sync has stopped"
                    )
                }
                return try await self.resolve(deviceID)
            },
            report: { [weak self] deviceID, event in
                await self?.apply(event, to: deviceID)
            },
            describeFailure: SyncFailureText.describe
        )
    }

    /// The peer's current address, resolved now rather than remembered.
    ///
    /// A peer this device has paired with but cannot currently see is the
    /// ordinary case — the other machine is asleep — so it fails here and the
    /// link retries rather than being torn down.
    func resolve(_ deviceID: SyncDeviceID) async throws -> ResolvedPeer {
        guard let discovery, let sighting = sighted[deviceID] else {
            throw DiscoveryError.resolutionFailed(
                peer: deviceID.fingerprint,
                reason: "not on the network"
            )
        }
        return try await discovery.resolve(sighting.peer)
    }

    /// Asks every link to exchange indexes now rather than at the end of its
    /// wait.
    ///
    /// A pin or a deletion reaches a peer on the next exchange, which is up to
    /// `PeerLink.resyncInterval` away. That is fine to wait for in ordinary use
    /// and no use at all to somebody who has just deleted something and wants to
    /// know it stuck — which is a step of this feature's own runbook.
    func syncNow() {
        for link in links.values {
            Task { await link.resync() }
        }
    }

    /// Folds one link's report into the row it belongs to.
    func apply(_ event: PeerLinkEvent, to deviceID: SyncDeviceID) {
        var entry = progress[deviceID] ?? PeerProgress()
        switch event {
        case .connecting:
            entry.link = .connecting
        case .connected(let name, let platform):
            entry.link = .connected
            entry.name = name
            entry.platform = platform
        case .synced(let learned, let at):
            entry.link = .connected
            entry.lastSyncedAt = at
            entry.received += learned
        case .pushed:
            entry.pushed += 1
        case .failed(let reason):
            entry.link = .failed(reason: reason)
        }
        progress[deviceID] = entry
        refreshRows()
    }
}
