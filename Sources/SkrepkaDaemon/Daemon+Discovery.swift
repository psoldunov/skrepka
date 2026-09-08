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
        let generation = nextAdvertisementGeneration()
        advertisementFailureTask = Task { [weak self] in
            let failures = await discovery.advertisementFailures()
            for await failure in failures {
                guard !Task.isCancelled else { return }
                await self?.advertisementLost(failure, generation: generation)
            }
        }
    }

    /// Stamps the watcher being started, and answers the stamp. See
    /// ``Daemon/advertisementGeneration``.
    func nextAdvertisementGeneration() -> Int {
        advertisementGeneration += 1
        return advertisementGeneration
    }

    /// Reports a loss, unless the watcher that saw it has been replaced.
    ///
    /// Cancellation alone does not settle this: a failure the outgoing watcher
    /// had already taken off its stream lands after the cancel, and acting on
    /// it would mark the *replacement* advertisement — the one that just
    /// published successfully — as lost, so `skrepka doctor` would report a
    /// problem that is not there until the daemon restarts.
    func advertisementLost(_ error: DiscoveryError, generation: Int) {
        guard generation == advertisementGeneration else { return }
        isPublished = false
        responderProblem = error.description
        logger.warning(
            "this device is no longer published",
            metadata: ["reason": .string(error.description)]
        )
    }
}
