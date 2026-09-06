import Foundation
import SkrepkaSync

/// What ``ProbeCommands`` needs from the running peer that is not the store.
extension ProbePeer {
    /// This device's identity, which every clipping it records is stamped with.
    func localDeviceID() async throws -> SyncDeviceID {
        guard let runtime else { throw ProbeError.unknownCommand("peer is not running") }
        return runtime.deviceID
    }

    /// The last thing one link reported, for `peers`.
    func state(of deviceID: SyncDeviceID) -> String? { linkState[deviceID] }

    /// Devices seen on the network but not paired, for `peers`.
    func sightingLines() -> [String] {
        #if canImport(Network) && canImport(dnssd)
            let paired = Set(links.keys)
            return sightings()
                .filter { !paired.contains($0.deviceID) }
                .map { sighting in
                    let pairable =
                        sighting.advertisement.pairingPort
                        .map { "pairable on \($0)" } ?? "not accepting pairings"
                    return "  seen    \(sighting.deviceID.fingerprint)  "
                        + "\(sighting.advertisement.displayName ?? sighting.peer.instanceName) "
                        + "(\(sighting.advertisement.platform.rawValue))  — \(pairable)"
                }
        #else
            return []
        #endif
    }

    /// Pairs with a peer at an address given by hand, and remembers where its
    /// *sync* listener is.
    ///
    /// The path Phase 6 needs before Avahi lands, and the one that makes this
    /// binary useful inside a container with no mDNS at all.
    ///
    /// **Both ports, and they are different ports.** Pairing happens on a
    /// listener that accepts an unpinned certificate and may carry nothing but
    /// the two pairing messages; history and live push happen on the pinned one.
    /// Recording the pairing port as the peer's address is how every later
    /// connection gets refused with "the peer sent hello on a connection that
    /// may only pair" — which is the transport working, and a caller that asked
    /// the wrong door.
    func connectManually(host: String, pairingPort: UInt16, syncPort: UInt16) async throws -> String {
        guard let runtime else { throw ProbeError.unknownCommand("peer is not running") }
        let connection = try await SyncClient.connect(
            host: host,
            port: Int(pairingPort),
            identity: runtime.certificate,
            policy: .pairing,
            group: runtime.group
        )
        defer { Task { await connection.close() } }
        let result = try await pair(over: connection, runtime: runtime)
        await setAddress(host: host, port: syncPort, for: connection.peerDeviceID)
        return "\(result)\nsync address \(host):\(syncPort) recorded"
    }

    /// Points an already-paired peer at an address, for a network with no mDNS.
    func setManualAddress(fingerprint: String, host: String, port: UInt16) async throws -> String {
        guard
            let peer = await store.pairedPeers()
                .first(where: { $0.deviceID.hex.hasPrefix(fingerprint) })
        else { return "no paired device starts with \(fingerprint)" }
        await setAddress(host: host, port: port, for: peer.deviceID)
        return "\(peer.deviceID.fingerprint) is at \(host):\(port)"
    }

    /// Asks every link to exchange indexes now rather than at the end of its
    /// wait. What "force a re-sync" means.
    func resyncAll() async -> String {
        guard !links.isEmpty else { return "no links to sync" }
        for link in links.values {
            await link.resync()
        }
        return "asked \(links.count) link(s) to sync now"
    }

    /// Pairs with a device seen on the network.
    func pair(with fingerprint: String) async throws -> String {
        #if canImport(Network) && canImport(dnssd)
            guard let runtime, let discovery else {
                throw ProbeError.unknownCommand("peer is not running")
            }
            guard
                let sighting = sightings().first(where: { $0.deviceID.hex.hasPrefix(fingerprint) })
            else { return "no device on this network starts with \(fingerprint)" }
            guard let pairingPort = sighting.advertisement.pairingPort else {
                return "\(sighting.deviceID.fingerprint) is not accepting new pairings"
            }
            let resolved = try await discovery.resolve(sighting.peer)
            let connection = try await SyncClient.connect(
                host: resolved.host,
                port: Int(pairingPort),
                identity: runtime.certificate,
                policy: .pairing,
                group: runtime.group
            )
            defer { Task { await connection.close() } }
            return try await pair(over: connection, runtime: runtime)
        #else
            _ = fingerprint
            return "no mDNS on this platform — use `connect HOST PAIRING_PORT SYNC_PORT`"
        #endif
    }

    /// The pairing exchange itself, over a connection somebody else opened.
    ///
    /// The code is printed rather than compared here. This peer has no screen
    /// and no user; the operator reads it beside the other machine's, which is
    /// the whole man-in-the-middle defence and the reason this binary is a test
    /// tool rather than a product.
    private func pair(over connection: SyncConnection, runtime: SyncRuntime) async throws -> String {
        let initiator = try SyncInitiator(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            expecting: nil
        )
        let proposal = try await initiator.pair(at: Date())
        try await store.savePairedPeer(proposal.peer)
        await pairedSetMayHaveChanged()
        return """
            paired with \(proposal.peer.deviceName) (\(proposal.peer.deviceID.fingerprint))
            code was \(proposal.shortAuthenticationString) — it had to match the other screen
            """
    }
}
