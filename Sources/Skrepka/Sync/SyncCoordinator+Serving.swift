import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// The listening half of ``SyncCoordinator``: the two servers, and the
/// responder that answers each connection they accept.
extension SyncCoordinator {
    /// Every interface, because a peer on the LAN is the point.
    ///
    /// Loopback is what the transport's own tests bind, and it is the wrong
    /// answer here: a Mac listening on `127.0.0.1` advertises a port on Bonjour
    /// that nothing off the machine can reach.
    static var listenHost: String { "0.0.0.0" }

    // MARK: - The pinned listener

    /// Starts the listener paired peers connect to.
    ///
    /// Its ``PinPolicy`` is fixed at the moment it starts, so pairing with a new
    /// device makes it stale — see ``restartSyncListener()``.
    ///
    /// - Parameter port: 0 for any free port, or the one already held. A restart
    ///   passes the port it was on: the alternative is a new port on every
    ///   pairing, which every peer then has to rediscover, and which a peer
    ///   reached by a written-down address cannot rediscover at all.
    func startSyncListener(runtime: SyncRuntime, port: Int = 0) async throws {
        let server = try await SyncServer.start(
            identity: runtime.certificate,
            policy: .pinned(Set(paired.keys)),
            host: Self.listenHost,
            port: port,
            group: runtime.group
        )
        syncServer = server
        acceptTask = Task { [weak self] in
            while let connection = await server.nextConnection() {
                self?.serve(connection)
            }
        }
    }

    /// Rebuilds the pinned listener around a changed paired set.
    ///
    /// A restart rather than a policy that can be swapped underneath a running
    /// server: the pinned set is read once, into the TLS verification callback,
    /// and reaching in to change it would mean touching the one piece of this
    /// stack where a mistake fails open. Pairing and unpairing are rare,
    /// deliberate, user-initiated acts, and the cost is that live links
    /// reconnect — which they are built to do anyway.
    ///
    /// The advertisement is republished afterwards, because the record carries
    /// the port and a rebind that could not take the old one has moved it.
    func restartSyncListener() async {
        guard let runtime else { return }
        acceptTask?.cancel()
        acceptTask = nil
        let port = syncServer?.port ?? 0
        await syncServer?.stop()
        syncServer = nil
        do {
            try await startSyncListener(runtime: runtime, port: port)
            try await republishAdvertisement()
        } catch {
            errorMessage = SyncFailureText.describe(error)
            SkrepkaLog.sync.error(
                "Could not restart the sync listener: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - The pairing listener

    /// Opens the window in which a device that has never paired with this one
    /// may connect, and advertises the port it should dial.
    func startPairingListener() async {
        guard let runtime, pairingServer == nil else { return }
        do {
            let server = try await SyncServer.start(
                identity: runtime.certificate,
                policy: .pairing,
                host: Self.listenHost,
                group: runtime.group
            )
            pairingServer = server
            isAcceptingPairing = true
            pairingAcceptTask = Task { [weak self] in
                while let connection = await server.nextConnection() {
                    self?.serve(connection)
                }
            }
            try await republishAdvertisement()
        } catch {
            await stopPairingListener()
            errorMessage = SyncFailureText.describe(error)
        }
    }

    func stopPairingListener() async {
        pairingAcceptTask?.cancel()
        pairingAcceptTask = nil
        await pairingServer?.stop()
        pairingServer = nil
        guard isAcceptingPairing else { return }
        isAcceptingPairing = false
        try? await republishAdvertisement()
    }

    /// Flips the pairing window, which is what the Sync pane's switch does.
    func setAcceptingPairing(_ accepting: Bool) async {
        accepting ? await startPairingListener() : await stopPairingListener()
    }

    // MARK: - Answering

    /// Answers one accepted connection until the peer goes.
    ///
    /// A task per connection, not awaited: ``SyncResponder/serve()`` runs for
    /// the life of the connection, and awaiting it here would stop the accept
    /// loop at the first peer.
    ///
    /// The responder is built with the live-push sink even on a
    /// ``PinPolicy/pairing`` connection, which cannot carry one —
    /// ``SyncConnection/receive()`` refuses every message outside the pairing
    /// pair — so the branch is unreachable there rather than guarded here. One
    /// construction site, and the rule stays in the transport where it is
    /// enforced.
    func serve(_ connection: SyncConnection) {
        guard let runtime else { return }
        let responder = SyncResponder(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            store: runtime.store,
            confirmPairing: { [weak self] proposal in
                await self?.confirmPairing(proposal, direction: .incoming) ?? false
            },
            onLivePush: { [weak self] meta, inline in
                await self?.receiveLivePush(meta, inline: inline)
            }
        )
        Task { [weak self] in
            do {
                try await responder.serve()
            } catch {
                SkrepkaLog.sync.notice(
                    "A peer connection ended: \(String(describing: error), privacy: .public)"
                )
            }
            await connection.close()
            // A pairing may have been saved by the responder itself, which is
            // the only path that writes one without this coordinator asking.
            await self?.pairedSetMayHaveChanged()
        }
    }

    /// Re-reads the paired set, and rebuilds whatever depended on it.
    ///
    /// Called after any path that could have written a pairing, rather than only
    /// after the ones this type drives: ``SyncResponder`` saves an accepted peer
    /// itself, so the listener's pinned set can go stale without this
    /// coordinator having initiated anything.
    func pairedSetMayHaveChanged() async {
        let before = Set(paired.keys)
        do {
            try await reloadPairedPeers()
        } catch {
            SkrepkaLog.sync.error(
                "Could not re-read paired devices: \(String(describing: error), privacy: .public)"
            )
            return
        }
        guard Set(paired.keys) != before else { return }
        await restartSyncListener()
        reconcileLinks()
    }
}
