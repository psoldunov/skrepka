import Foundation
import SkrepkaSync

/// Finding peers, and keeping one outbound link to each.
///
/// Two ways to reach a peer, and the probe needs both. Bonjour where the
/// platform has it — which today is macOS, so the runbook can have the Mac find
/// the probe and the probe find the Mac. An address typed in with `connect`
/// where it does not, which is every Linux container this will run in until
/// Phase 6 writes the Avahi conformance.
extension ProbePeer {
    // MARK: - Advertising and browsing

    func startDiscovery() async throws {
        #if canImport(Network) && canImport(dnssd)
            let discovery = BonjourDiscovery()
            self.discovery = discovery
            try await discovery.startAdvertising(descriptor())
            let events = try await discovery.startBrowsing()
            browseTask = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        #else
            ProbeOutput.say(
                """
                no mDNS on this platform yet — use `connect HOST PORT` to reach a peer, \
                and give this peer's address to the other side.
                """
            )
        #endif
    }

    func stopDiscovery() async {
        #if canImport(Network) && canImport(dnssd)
            browseTask?.cancel()
            browseTask = nil
            await discovery?.stopAdvertising()
            await discovery?.stopBrowsing()
            discovery = nil
        #endif
    }

    func republishAdvertisement() async throws {
        #if canImport(Network) && canImport(dnssd)
            guard let discovery else { return }
            await discovery.stopAdvertising()
            try await discovery.startAdvertising(descriptor())
        #endif
    }

    #if canImport(Network) && canImport(dnssd)
        private func descriptor() -> ServiceDescriptor {
            ServiceDescriptor(
                displayName: options.name,
                port: UInt16(syncServer?.port ?? 0),
                deviceID: runtime?.deviceID ?? SyncDeviceID(certificateDER: Data()),
                platform: options.platform,
                pairingPort: pairingServer.map { UInt16($0.port) }
            )
        }

        private func handle(_ event: DiscoveryEvent) async {
            switch event {
            case .appeared(let peer), .changed(let peer):
                guard case .read(let advertisement) = peer.advertisement,
                    advertisement.deviceID != runtime?.deviceID
                else { return }
                sighted[advertisement.deviceID] = peer
            case .disappeared(let peer):
                guard case .read(let advertisement) = peer.advertisement else { return }
                sighted[advertisement.deviceID] = nil
            case .ready, .stalled, .failed:
                break
            }
            await reconcileLinks()
        }

        /// Peers seen on the network, for `peers` and for `pair`.
        func sightings() -> [Sighting] {
            sighted.compactMap { deviceID, peer in
                guard case .read(let advertisement) = peer.advertisement else { return nil }
                return Sighting(deviceID: deviceID, peer: peer, advertisement: advertisement)
            }
        }
    #endif

    // MARK: - Links

    /// One link per paired peer, started and stopped as the set changes.
    func reconcileLinks() async {
        guard let runtime else { return }
        let paired = await store.pairedPeers().map(\.deviceID)
        for deviceID in links.keys where !paired.contains(deviceID) {
            await links.removeValue(forKey: deviceID)?.stop()
            linkState[deviceID] = nil
        }
        for deviceID in paired where links[deviceID] == nil {
            let link = PeerLink(
                peerDeviceID: deviceID,
                runtime: runtime,
                resolve: { [weak self] in
                    guard let self else {
                        throw ProbeError.unknownCommand("peer has stopped")
                    }
                    return try await self.resolve(deviceID)
                },
                report: { [weak self] deviceID, event in
                    await self?.record(event, for: deviceID)
                }
            )
            links[deviceID] = link
            await link.start()
        }
    }

    /// The peer's address: what was typed in, or what mDNS answers.
    ///
    /// A manual address wins, because somebody who typed one meant it — and on
    /// a network where both are available, the typed one is the one being
    /// tested.
    func resolve(_ deviceID: SyncDeviceID) async throws -> ResolvedPeer {
        if let manual = manualAddresses[deviceID] {
            return Self.resolved(deviceID, host: manual.host, port: manual.port)
        }
        #if canImport(Network) && canImport(dnssd)
            if let discovery, let peer = sighted[deviceID] {
                return try await discovery.resolve(peer)
            }
        #endif
        throw ProbeError.unknownCommand("no address for \(deviceID.fingerprint)")
    }

    /// A `ResolvedPeer` for an address given by hand.
    ///
    /// `PeerLink` takes one of these because discovery is the ordinary way to
    /// get an address; a typed one is still an address, and inventing the browse
    /// result around it is cheaper than a second dialling path that could drift
    /// from the tested one.
    private static func resolved(_ deviceID: SyncDeviceID, host: String, port: UInt16) -> ResolvedPeer {
        let advertisement = PeerAdvertisement(
            deviceID: deviceID,
            displayName: nil,
            platform: .unknown,
            protocolVersion: .current
        )
        return ResolvedPeer(
            peer: DiscoveredPeer(
                instanceName: deviceID.fingerprint,
                serviceType: ServiceDescriptor.serviceType,
                domain: "local.",
                interfaceIndex: nil,
                advertisement: .read(advertisement)
            ),
            host: host,
            port: port,
            advertisement: advertisement
        )
    }

    private func record(_ event: PeerLinkEvent, for deviceID: SyncDeviceID) {
        switch event {
        case .connecting: linkState[deviceID] = "connecting"
        case .connected(let name, let platform):
            linkState[deviceID] = "connected to \(name) (\(platform.rawValue))"
        case .synced(let learned, _): linkState[deviceID] = "synced, learned \(learned)"
        case .pushed: linkState[deviceID] = "pushed"
        case .failed(let reason): linkState[deviceID] = "failed: \(reason)"
        }
    }

    /// Records an address for a peer, and dials it if it is already paired.
    func setAddress(host: String, port: UInt16, for deviceID: SyncDeviceID) async {
        manualAddresses[deviceID] = (host, port)
        await reconcileLinks()
    }

    /// Pushes a clipping to every peer that has live push on.
    func pushToPeers(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async {
        let peers = await store.pairedPeers()
        for peer in peers {
            let choice = await store.livePushChoice(for: peer.deviceID)
            let setting = LivePushSetting(
                local: options.platform,
                remote: peer.platform,
                choice: choice
            )
            guard setting.isOn, let link = links[peer.deviceID] else { continue }
            await link.push(meta, payloads: payloads)
        }
    }
}

/// One device the browse turned up, with its record already read.
///
/// A named type rather than a tuple, because the tuple's labels put the
/// signature past the line the formatter breaks at, and a broken signature trips
/// the repo's own brace rule. Naming it is the smaller change and it reads
/// better at both call sites.
struct Sighting: Sendable {
    let deviceID: SyncDeviceID
    let peer: DiscoveredPeer
    let advertisement: PeerAdvertisement
}
