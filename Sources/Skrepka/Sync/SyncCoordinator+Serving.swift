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
    /// Queued, so two of these cannot overlap.
    ///
    /// They could: this is reached from ``pairedSetMayHaveChanged()``, which
    /// fires both when a `serve` task finishes and when the user taps Forget, so
    /// an inbound pairing completing while a peer is being removed ran two at
    /// once. Suspended inside `SyncServer.start`, the first left `syncServer`
    /// nil, so the second read port 0 and bound a fresh one; whichever returned
    /// last overwrote `syncServer` and `acceptTask` without stopping the other,
    /// leaving a listener bound with its own accept loop — and, where it had
    /// read `paired` before the removal, still pinning the peer the user had
    /// just forgotten.
    func restartSyncListener() async {
        await enqueueLifecycle { [weak self] in await self?.performRestartSyncListener() }.value
    }

    private func performRestartSyncListener() async {
        guard !isTearingDown, let runtime else { return }
        acceptTask?.cancel()
        acceptTask = nil
        let port = syncServer?.port ?? 0
        await syncServer?.stop()
        syncServer = nil
        do {
            try await startSyncListener(runtime: runtime, port: port)
            await republishAdvertisement()
        } catch {
            showMessage(SyncFailureText.describe(error), from: .elsewhere)
            SkrepkaLog.sync.error(
                "Could not restart the sync listener: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - The pairing listener

    /// How long the pairing window stays open before it closes itself.
    ///
    /// It is an *unpinned* listener: it accepts a device this Mac has never met,
    /// which is the one place in the stack where a stranger is allowed to get as
    /// far as raising a sheet. Every attack on first contact needs it open, so
    /// how long it stays open is a security parameter and not a convenience.
    ///
    /// Five minutes is what pairing actually takes: open the pane here, walk to
    /// the other machine, start pairing there, and compare nineteen characters
    /// on two screens. It is not long enough to leave running by accident, which
    /// is the failure this replaces — nothing used to close the window after a
    /// successful pairing, so a user who switched it on once left an unpinned
    /// port bound and `pair=` advertised to the LAN until they remembered.
    static let pairingWindow: Duration = .seconds(5 * 60)

    /// Opens the window in which a device that has never paired with this one
    /// may connect, and advertises the port it should dial.
    ///
    /// Closes itself two ways: ``pairedSetMayHaveChanged()`` shuts it the moment
    /// a pairing is actually recorded, and ``pairingWindow`` shuts it if none
    /// ever is.
    ///
    /// Reached only through ``setAcceptingPairing(_:)``, which is what queues it.
    /// There is deliberately no `async` wrapper that enqueues on a caller's
    /// behalf: opening this window is a thing exactly one control does, and a
    /// second entry point is a second place to forget that awaiting the queue
    /// from inside it deadlocks.
    private func performStartPairingListener() async {
        guard !isTearingDown, let runtime, pairingServer == nil else { return }
        do {
            let server = try await SyncServer.start(
                identity: runtime.certificate,
                policy: .pairing,
                host: Self.listenHost,
                group: runtime.group
            )
            // Re-checked after the await. The lifecycle queue makes an overlapping
            // toggle impossible, so this is the belt to that braces: a tear-down
            // that began while the bind was in flight must not end with an
            // unpinned listener bound and advertised. `SyncRuntime` is a value,
            // so there is no identity to compare — its presence is the signal.
            guard !isTearingDown, self.runtime != nil else {
                await server.stop()
                return
            }
            pairingServer = server
            isAcceptingPairing = true
            pairingWindowGeneration += 1
            let generation = pairingWindowGeneration
            pairingAcceptTask = Task { [weak self] in
                while let connection = await server.nextConnection() {
                    self?.serve(connection)
                }
            }
            pairingExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: Self.pairingWindow)
                guard !Task.isCancelled else { return }
                // Its own generation, so an expiry that somehow outlives its
                // cancellation cannot shut a later window.
                self?.closePairingWindow(because: .expired, generation: generation)
            }
            await republishAdvertisement()
        } catch {
            await performStopPairingListener()
            showMessage(SyncFailureText.describe(error), from: .elsewhere)
        }
    }

    /// Shuts the listener and unadvertises `pair=`.
    ///
    /// Every caller is already inside queued work — ``performStop()``,
    /// ``closePairingWindow(because:generation:)`` and
    /// ``setAcceptingPairing(_:)`` — so there is no `async` wrapper that enqueues
    /// on their behalf. There was, and it became unreachable the moment
    /// `closePairingWindow` started queuing its own guard; leaving it would have
    /// left an entry point whose only remaining use was to deadlock, since
    /// awaiting it from inside the queue waits on the queue that is waiting on
    /// it.
    func performStopPairingListener() async {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingAcceptTask?.cancel()
        pairingAcceptTask = nil
        await pairingServer?.stop()
        pairingServer = nil
        guard isAcceptingPairing else { return }
        isAcceptingPairing = false
        await republishAdvertisement()
    }

    /// Why the pairing window closed, for the line the user reads.
    enum PairingWindowClosure {
        case paired
        case expired
    }

    /// Shuts the pairing window `generation` names, unless it is already shut or
    /// a later one has since opened.
    ///
    /// The switch in the Sync pane is bound to ``isAcceptingPairing``, so this
    /// also puts the switch back — a window that closed itself while the control
    /// still read "on" would be the interface lying about an open port.
    ///
    /// **Synchronous, and the generation is checked inside the queued work.**
    /// Both closers decide before their work reaches the queue, so the check has
    /// to happen where the work runs rather than where it was asked for: a user
    /// who pairs one device and immediately reopens the window to pair a second
    /// would otherwise have the first pairing's close land on the second window.
    /// See ``SyncCoordinator/pairingWindowGeneration``.
    func closePairingWindow(because reason: PairingWindowClosure, generation: Int) {
        enqueueLifecycle { [weak self] in
            guard let self, isAcceptingPairing, generation == pairingWindowGeneration else { return }
            await performStopPairingListener()
            switch reason {
            case .paired:
                SkrepkaLog.sync.notice("Closed the pairing window: a device paired.")
            case .expired:
                SkrepkaLog.sync.notice("Closed the pairing window: nothing paired within it.")
            }
        }
    }

    /// Flips the pairing window, which is what the Sync pane's switch does.
    ///
    /// **Synchronous, and queues the work itself**, for the same reason
    /// ``SyncCoordinator/isEnabled``'s `didSet` does. A caller that wraps this in
    /// its own `Task` hands two flips to two unordered tasks, and then it is
    /// undefined which of them reaches the queue first — so an on-then-off can
    /// enqueue off-then-on and leave an unpinned listener bound after the user
    /// asked for it closed. Queuing from the setter is what makes the order the
    /// user's order.
    func setAcceptingPairing(_ accepting: Bool) {
        enqueueLifecycle { [weak self] in
            guard let self else { return }
            accepting
                ? await performStartPairingListener()
                : await performStopPairingListener()
        }
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
        // A device actually paired, so the window it came through has done its
        // job and closes. Only on growth: forgetting a peer also lands here, and
        // that is not a reason to shut a window the user has just opened to add
        // the replacement.
        if Set(paired.keys).count > before.count {
            closePairingWindow(because: .paired, generation: pairingWindowGeneration)
        }
        await restartSyncListener()
        reconcileLinks()
    }
}
