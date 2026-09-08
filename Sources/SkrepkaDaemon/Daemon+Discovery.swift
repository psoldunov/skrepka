import Foundation
import Logging
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// Starts browsing, and publishes once the browse says it is running.
    ///
    /// **A responder that is not there is reported and stepped over**, not
    /// thrown. A machine with no `avahi-daemon` still captures its own
    /// clipboard and still answers `skrepka list`; what it cannot do is find
    /// peers, and `skrepka doctor` is where that is said. Refusing to start
    /// would turn a missing package into a broken clipboard manager.
    func startDiscovery(runtime: SyncRuntime) async {
        let discovery = AvahiDiscovery(session: systemBus, logger: logger)
        switch await discovery.probe() {
        case .success(let version):
            logger.info("found avahi", metadata: ["version": .string(version)])
            responderProblem = nil
        case .failure(let error):
            responderProblem = error.description
            logger.warning(
                "no mDNS responder; this device will not find peers",
                metadata: ["reason": .string(error.description)]
            )
            await discovery.stopEverything()
            return
        }

        self.discovery = discovery
        do {
            let events = try await discovery.startBrowsing()
            browseTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event)
                }
            }
        } catch {
            responderProblem = String(describing: error)
            logger.warning(
                "could not browse for peers",
                metadata: ["reason": .string(String(describing: error))]
            )
        }
    }

    /// One browse event.
    ///
    /// Every case falls through to reconciling links, which is what makes a
    /// peer that reappears get dialled again without anything else noticing it
    /// went.
    func handle(_ event: DiscoveryEvent) async {
        switch event {
        case .appeared(let peer), .changed(let peer):
            await record(peer)
        case .disappeared(let peer):
            forget(peer)
        case .ready:
            responderProblem = nil
            await publishAdvertisement()
        case .stalled(let error):
            responderProblem = error.description
        case .failed(let error):
            responderProblem = error.description
            isPublished = false
            logger.warning("the browse failed", metadata: ["reason": .string(error.description)])
        }
        await reconcileLinks()
    }

    /// Resolves a browse result far enough to know who it is.
    ///
    /// **Avahi's browse signals carry no TXT record**, so unlike the macOS
    /// backend this costs a round trip per sighting. Worth it: without the
    /// record there is no device identifier, and without that a sighting cannot
    /// be matched to a paired peer or shown to a user as anything but an
    /// instance name.
    func record(_ peer: DiscoveredPeer) async {
        guard let discovery else { return }
        let advertisement: PeerAdvertisement
        switch peer.advertisement {
        case .read(let known):
            advertisement = known
        case .unread:
            do {
                advertisement = try await discovery.resolve(peer).advertisement
            } catch {
                // Dropped for the same reason `.unreadable` is — no device
                // identifier means nothing to file the sighting under — and
                // logged for the same reason too: a peer that is invisible
                // because its resolve keeps failing looks exactly like a peer
                // that is switched off.
                logger.notice(
                    "a peer could not be resolved, so it is not listed",
                    metadata: [
                        "peer": .string(peer.instanceName),
                        "error": .string(String(describing: error)),
                    ]
                )
                return
            }
        case .unreadable(let error):
            // Logged and dropped, because there is no device identifier to file
            // it under. A machine with a broken record is invisible rather than
            // half-read — the trade `TXTRecord` documents.
            logger.notice(
                "a peer advertises a record this build cannot read",
                metadata: ["peer": .string(peer.instanceName), "error": .string(error.description)]
            )
            return
        }
        guard advertisement.deviceID != runtime?.deviceID else { return }
        sighted[advertisement.deviceID] = Sighting(peer: peer, advertisement: advertisement)
    }

    func forget(_ peer: DiscoveredPeer) {
        for (deviceID, sighting) in sighted where sighting.peer.instanceName == peer.instanceName {
            sighted[deviceID] = nil
        }
    }

    // MARK: - Publishing

    func publishAdvertisement() async {
        guard !isStopping, let discovery, let runtime, let syncServer else { return }
        let wanted = descriptor(runtime: runtime, syncPort: UInt16(syncServer.port))
        do {
            try await discovery.updateAdvertisement(wanted)
            isPublished = true
            responderProblem = nil
            watchAdvertisementFailures(discovery)
        } catch {
            isPublished = false
            responderProblem = String(describing: error)
            logger.warning(
                "could not publish this device",
                metadata: ["reason": .string(String(describing: error))]
            )
        }
    }

    /// Republishes after something outside the TXT record changed — which in
    /// practice is the pairing window opening or closing.
    ///
    /// Silent before the first publish: `updateAdvertisement` would publish
    /// outright, and doing that from here would advertise a device whose browse
    /// has not come up.
    func republishAdvertisement() async {
        guard isPublished else { return }
        await publishAdvertisement()
    }

    private func descriptor(runtime: SyncRuntime, syncPort: UInt16) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: displayName,
            port: syncPort,
            deviceID: runtime.deviceID,
            platform: .linux,
            // Absent means "not accepting new pairings", which a peer can show
            // rather than fail on — and is the smaller attack surface, since a
            // stranger cannot complete a handshake with a device that is not
            // currently pairing.
            pairingPort: pairingServer.map { UInt16($0.port) }
        )
    }

    /// Reports a record that was published and then withdrawn.
    ///
    /// Without this a device drops off the network with nothing anywhere saying
    /// so — which on a headless daemon means a user staring at a peer list on
    /// the other machine wondering where this one went.
    /// Replaces the watcher rather than adding one. See
    /// ``Daemon/advertisementFailureTask``.
    private func watchAdvertisementFailures(_ discovery: AvahiDiscovery) {
        advertisementFailureTask?.cancel()
        advertisementFailureTask = Task { [weak self] in
            let failures = await discovery.advertisementFailures()
            for await failure in failures {
                guard !Task.isCancelled else { return }
                await self?.advertisementLost(failure)
            }
        }
    }

    func advertisementLost(_ error: DiscoveryError) {
        isPublished = false
        responderProblem = error.description
        logger.warning(
            "this device is no longer published",
            metadata: ["reason": .string(error.description)]
        )
    }

    // MARK: - Links

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
