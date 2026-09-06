import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// The finding-and-being-found half of ``SyncCoordinator``, and the links it
/// keeps up as a result.
extension SyncCoordinator {
    // MARK: - Advertising and browsing

    /// Starts looking for peers — and nothing else.
    ///
    /// Named for what it does now. Publishing this device used to happen here
    /// too and is now ``performPublish()``, which the browse itself triggers;
    /// see ``SyncCoordinator/bringUp()`` for why the order matters. It takes no
    /// `SyncRuntime` for the same reason: browsing asks nothing about this
    /// device, and only publishing did.
    func startBrowsing() async throws {
        let discovery = BonjourDiscovery()
        self.discovery = discovery
        try await watchBrowse(discovery)
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
            // Discovery's message only. A pairing that just failed, a live-push
            // setting that would not save and a listener that would not rebind
            // all share this slot, and a browse recovering is not news about any
            // of them.
            clearMessage(from: .discovery)
            // A fresh `.ready` is a fresh chance, so the attempt count starts
            // over: whatever stopped the last publish is not what this one will
            // hit. It also means granting access after the schedule ran out
            // publishes rather than staying given-up.
            publishAttempts = 0
            // The rest of the bring-up, now that macOS is letting this app onto
            // the network. Queued rather than awaited: this runs on the browse
            // task, and publishing mutates the running stack.
            enqueueLifecycle { [weak self] in await self?.performPublish() }
        case .stalled(let error), .failed(let error):
            isLocalNetworkDenied = error == .localNetworkDenied
            showMessage(Self.browseMessage(error), from: .discovery)
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

    /// What the user is told about a browse that is not running.
    ///
    /// Two answers, because there are two reasons and only one of them is
    /// anybody's fault. A browse also waits while the Mac has no network at all
    /// — a closed lid, a Wi-Fi network being joined — and sending that user to
    /// System Settings to grant a permission they have already granted is a
    /// wasted trip. See ``DiscoveryError/localNetworkDenied``.
    private static func browseMessage(_ error: DiscoveryError) -> String {
        switch error {
        case .localNetworkDenied:
            SyncFailureText.localNetworkDenied
        default:
            "Skrepka cannot see the local network yet. (\(String(describing: error)))"
        }
    }

    // MARK: - Links

    /// Starts a link for every paired peer and stops the ones that no longer
    /// belong.
    ///
    /// Idempotent, and called from every path that changes either set —
    /// ``PeerLink/start()`` on a running link does nothing, so a browse event
    /// that re-announces a peer costs nothing.
    /// Refuses to build anything while sync is going away, or before this
    /// device has been published.
    ///
    /// The second guard is the permission gate. Dialling a peer is an outgoing
    /// TCP connection to a local address, and resolving its address first is a
    /// Bonjour query; TN3179 gates both on the Local Network privilege exactly
    /// as it gates the browse. This is reached from every browse event including
    /// the ones that report the browse *waiting* for that privilege, so without
    /// the guard the app answers "you may not have the network yet" by dialling
    /// every paired peer — which is the second and third system prompt landing
    /// on top of the first.
    ///
    /// `runtime` is not the flag to read for that: ``SyncCoordinator/stop()``
    /// nils it at the *end* of a tear-down that takes several awaits, and this
    /// is reached from two places that do not go through the lifecycle queue —
    /// a browse event already dispatched before `browseTask` was cancelled, and
    /// a `serve` task finishing into ``pairedSetMayHaveChanged()``. Either one
    /// landing after `links.removeAll()` used to rebuild a link for every peer
    /// still in `paired`, which the tear-down had already walked past. Those
    /// links then dialled forever against a shut-down event-loop group.
    func reconcileLinks() {
        guard !isTearingDown, isPublished, let runtime else { return }
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
