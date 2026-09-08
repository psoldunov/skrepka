import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// Starts the pinned listener and the loop that answers what arrives on it.
    ///
    /// The pin set is baked into the TLS verification callback when the server
    /// starts, because that callback runs on an event loop and cannot await a
    /// store. A changed paired set therefore means restarting the listener
    /// rather than mutating it — see ``performRestartSyncListener()``.
    ///
    /// A pin set that could not be read is a thrown error and not an empty
    /// set: binding on `[]` would leave a listener that rejects every paired
    /// peer, so one locked read would un-pair the machine until the next
    /// restart. Start-up fails outright on it and the rebind reports it, which
    /// is the same trade ``pairedSetMayHaveChanged()`` makes — no listener is
    /// recoverable, a listener that pins nothing is not.
    func startSyncListener(runtime: SyncRuntime, port: Int) async throws {
        let pinned = try await trust.pinnedDeviceIDs()
        let server = try await SyncServer.start(
            identity: runtime.certificate,
            policy: .pinned(pinned),
            host: Self.listenHost,
            port: port,
            group: runtime.group
        )
        syncServer = server
        syncAcceptTask = acceptLoop(on: server)
    }

    /// Rebinds the pinned listener on the same port, so the advertisement stays
    /// true.
    ///
    /// Cancels **only** the pinned accept loop. The pairing loop and the live
    /// connections have their own handles, because a paired set that changed is
    /// no reason to close an open pairing window or to cut a peer off mid-
    /// exchange.
    ///
    /// `perform`-prefixed because it must run inside queued lifecycle work —
    /// it stops a server and binds another across two awaits, which is the
    /// same window ``Daemon/openPairing(for:)`` was queued to close. Its one
    /// caller is ``performPairedSetMayHaveChanged()``, which is the queued
    /// half.
    func performRestartSyncListener() async {
        guard !isStopping, let runtime else { return }
        syncAcceptTask?.cancel()
        syncAcceptTask = nil
        let port = syncServer?.port ?? options.port
        await syncServer?.stop()
        syncServer = nil
        do {
            try await startSyncListener(runtime: runtime, port: port)
            await republishAdvertisement()
        } catch {
            logger.error(
                "could not rebind the sync listener",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }

    private func acceptLoop(on server: SyncServer) -> Task<Void, Never> {
        Task { [weak self] in
            while let connection = await server.nextConnection() {
                guard !Task.isCancelled else { return }
                await self?.serve(connection)
            }
        }
    }

    /// Answers one verified connection.
    ///
    /// One task per connection, not awaited: a peer that connects and then says
    /// nothing must not hold up the next one. `SyncServer` already caps how
    /// many can be in flight and puts a deadline on each handshake, so an
    /// unbounded fan of these is not what it looks like.
    func serve(_ connection: SyncConnection) {
        guard let runtime else { return }
        let responder = SyncResponder(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            store: runtime.store,
            confirmPairing: { [weak self] proposal in
                await self?.confirmPairing(proposal, direction: PairingDirection.incoming) ?? false
            },
            onLivePush: { [weak self] meta, inline in
                await self?.receiveLivePush(meta, inline: inline)
            }
        )
        // Keyed, and the task removes its own entry when it finishes. An
        // append-only list of these grew by one for every connection the daemon
        // ever answered.
        let id = UUID()
        let task = Task { [weak self] in
            do {
                try await responder.serve()
            } catch {
                // Logged rather than surfaced: a connection ending is ordinary
                // — a peer sleeping, a Wi-Fi drop — and the peer list already
                // shows the link state. What is worth keeping is the reason,
                // for whoever reads the journal after a pairing would not take.
                self?.logConnectionEnd(error)
            }
            await connection.close()
            await self?.pairedSetMayHaveChanged()
            await self?.finishedConnection(id)
        }
        // No suspension between the two, because `serve` is synchronous — so
        // the task cannot reach `finishedConnection` before its entry exists.
        connectionTasks[id] = task
    }

    func finishedConnection(_ id: UUID) {
        connectionTasks[id] = nil
    }

    nonisolated func logConnectionEnd(_ error: any Error) {
        logger.debug(
            "a peer connection ended",
            metadata: ["reason": .string(String(describing: error))]
        )
    }

    /// Re-reads the paired set, and rebinds the pinned listener if it grew.
    ///
    /// The listener's pin set is fixed at bind time, so a device that has just
    /// paired cannot reach the pinned port until this runs. Closing the pairing
    /// window at the same moment is deliberate: the window exists to admit one
    /// device, and leaving it open afterwards leaves the one listener that
    /// accepts an unapproved certificate running for no reason.
    /// A read that fails leaves everything alone. `(try? …) ?? []` could not
    /// tell "nobody is paired" from "the store was busy", and an empty set
    /// here stops every link and rebinds the listener with a pin set that
    /// rejects every peer — one locked read would un-pair the machine until
    /// the next restart.
    ///
    /// Queued as one unit, because it is the counterparty to
    /// ``Daemon/openPairing(for:)``: unqueued it closed the pairing window and
    /// rebound the listener from a connection task, so it could run between
    /// `performOpenPairing`'s `await SyncServer.start` and the assignment
    /// after it — see `pairingServer` there — and orphan the listener it had
    /// just decided was already gone. One `enqueue` and not three, so nothing
    /// else in the lifecycle interleaves between the close and the rebind.
    func pairedSetMayHaveChanged() async {
        await enqueue { await $0.performPairedSetMayHaveChanged() }.value
    }

    func performPairedSetMayHaveChanged() async {
        guard !isStopping else { return }
        let peers: [PairedPeer]
        do {
            peers = try await trust.pairedPeers()
        } catch {
            logger.error(
                "could not re-read the paired devices; leaving the links and the listener alone",
                metadata: ["error": .string(String(describing: error))]
            )
            return
        }
        let paired = Set(peers.map(\.deviceID))
        let known = Set(links.keys)
        guard paired != known else { return }
        if paired.count > known.count, pairingServer != nil {
            await performClosePairing()
        }
        await performRestartSyncListener()
        await reconcileLinks()
    }

    // MARK: - Inbound live push

    /// Puts content a peer pushed onto this machine's clipboard.
    ///
    /// The item is already in history by the time this runs — `SyncResponder`
    /// stores before it calls the sink — so everything here is about the
    /// clipboard and nothing here can cost the row.
    ///
    /// The hash is remembered **before** the write, not after: the write is
    /// what the watcher might see, so a set updated afterwards would be updated
    /// after the race it exists to lose.
    ///
    /// **A push whose bytes did not come inline writes nothing**, which is the
    /// same limitation the macOS side has: `LivePushPayload.inline` sends
    /// nothing when a push's representations total more than
    /// `SyncLimits.livePushInlineLimit`, which is most images. The item is
    /// still in history and its bytes arrive on the next index exchange; what
    /// the user loses is the handoff, not the clipping.
    func receiveLivePush(_ meta: SyncClipMeta, inline: [RepresentationKey: Data]) async {
        guard !isStopping, !meta.isConcealed, !inline.isEmpty else { return }
        recentlyReceived.remember(meta.contentHash, at: Date())
        notifyHistoryChanged()
        await writeToClipboard(inline)
    }

    /// Writes wire-keyed bytes to the session's clipboard.
    ///
    /// The watcher is paused around the write, which is the primary echo
    /// suppression; `recentlyReceived` is the backstop for the window between
    /// the two. Both, because either alone has a gap: a pause that is missed
    /// because the backend delivered the change first would recapture, and a
    /// hash set alone would not stop the capture, only the push.
    func writeToClipboard(_ payloads: [RepresentationKey: Data]) async {
        guard let clipboard else { return }
        let targets = LinuxClipboardWriter.targets(for: payloads)
        guard !targets.isEmpty else { return }
        await watcher?.pause()
        await clipboard.setSelection(targets)
        await watcher?.resume()
    }
}

/// Which way a pairing connection went, as the IPC documents spell it.
enum PairingDirection {
    static let incoming = "incoming"
    static let outgoing = "outgoing"
}
