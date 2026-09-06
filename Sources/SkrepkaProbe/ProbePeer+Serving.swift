import Foundation
import SkrepkaSync

/// The listening half of ``ProbePeer``: two servers, and one responder per
/// connection.
extension ProbePeer {
    /// Every interface. The probe exists to be reached from another machine.
    static var listenHost: String { "0.0.0.0" }

    func startListeners() async throws {
        guard let runtime else { return }
        syncServer = try await SyncServer.start(
            identity: runtime.certificate,
            policy: .pinned(Set(await store.pairedPeers().map(\.deviceID))),
            host: Self.listenHost,
            port: options.port,
            group: runtime.group
        )
        accept(from: syncServer)

        guard options.opensPairingListener else { return }
        pairingServer = try await SyncServer.start(
            identity: runtime.certificate,
            policy: .pairing,
            host: Self.listenHost,
            group: runtime.group
        )
        accept(from: pairingServer)
    }

    /// Rebuilds the pinned listener around a changed paired set.
    ///
    /// The same restart the app does, for the same reason: the pinned set is
    /// read once into the TLS verification callback, and reaching in to change
    /// it would mean touching the one piece of this stack where a mistake fails
    /// open.
    /// Rebinds the port it was already on, not `options.port`, which is 0 by
    /// default. A restart that took a new port would strand every peer holding
    /// the old one — including one reached by an address typed into `connect`,
    /// which has no way to rediscover it.
    func restartSyncListener() async {
        guard let runtime else { return }
        let port = syncServer?.port ?? options.port
        await syncServer?.stop()
        syncServer = nil
        do {
            syncServer = try await SyncServer.start(
                identity: runtime.certificate,
                policy: .pinned(Set(await store.pairedPeers().map(\.deviceID))),
                host: Self.listenHost,
                port: port,
                group: runtime.group
            )
            accept(from: syncServer)
            try await republishAdvertisement()
        } catch {
            ProbeOutput.fail("could not restart the sync listener: \(error)")
        }
    }

    private func accept(from server: SyncServer?) {
        guard let server else { return }
        acceptTasks.append(
            Task { [weak self] in
                while let connection = await server.nextConnection() {
                    await self?.serve(connection)
                }
            }
        )
    }

    /// Answers one connection until the peer goes.
    ///
    /// The live-push sink prints rather than writing anywhere: this peer has no
    /// clipboard, and the whole value of that is that a live push arriving here
    /// is *visible* rather than silently applied.
    private func serve(_ connection: SyncConnection) {
        guard let runtime else { return }
        let responder = SyncResponder(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            store: runtime.store,
            confirmPairing: { [weak self] proposal in
                await self?.confirmPairing(proposal) ?? false
            },
            onLivePush: { meta, inline in
                ProbeOutput.say(
                    """
                    live push  \(meta.contentHash.prefix(12))  \
                    \(inline.isEmpty ? "metadata only" : "\(inline.count) representation(s)")  \
                    \(ProbeFormat.oneLine(meta.preview))
                    """
                )
            }
        )
        Task { [weak self] in
            do {
                try await responder.serve()
            } catch {
                ProbeOutput.say("peer connection ended: \(error)")
            }
            await connection.close()
            await self?.pairedSetMayHaveChanged()
        }
    }

    /// Answers an incoming pairing.
    ///
    /// Prints the code either way, because printing it is what makes the
    /// comparison possible at all — the operator reads it here and on the other
    /// machine's screen. `--confirm-pairing` then waits for `accept` or
    /// `reject`, which is what runbook steps 1 and 2 need; without it the probe
    /// accepts, which is the right default for a scripted run and the wrong one
    /// for a security claim.
    func confirmPairing(_ proposal: PairingProposal) async -> Bool {
        ProbeOutput.say(
            """

            ── pairing request ──────────────────────────────
              device  \(proposal.peer.deviceName) (\(proposal.peer.deviceID.fingerprint))
              code    \(proposal.shortAuthenticationString)
            \(options.confirmsPairing
                ? "  compare it with the other screen, then: accept | reject"
                : "  accepted automatically (start with --confirm-pairing to be asked)")
            ─────────────────────────────────────────────────
            """
        )
        guard options.confirmsPairing else { return true }
        guard pendingPairing == nil else {
            ProbeOutput.fail("another pairing is already waiting; refusing this one")
            return false
        }
        return await withCheckedContinuation { continuation in
            pendingPairing = continuation
        }
    }

    /// The operator's answer to a waiting pairing.
    func answerPairing(_ accepted: Bool) -> String {
        guard let continuation = pendingPairing else { return "nothing is waiting to be paired" }
        pendingPairing = nil
        continuation.resume(returning: accepted)
        return accepted ? "paired" : "refused"
    }

    /// Re-reads the paired set and rebuilds whatever depended on it.
    ///
    /// The responder saves an accepted peer itself, so the listener's pinned set
    /// can go stale without this actor having initiated anything.
    func pairedSetMayHaveChanged() async {
        await restartSyncListener()
        await reconcileLinks()
    }
}

/// Shared formatting, so two commands do not render the same value two ways.
enum ProbeFormat {
    /// A preview on one line, clipped, so a list stays a list.
    static func oneLine(_ text: String, limit: Int = 60) -> String {
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return flattened.prefix(limit) + "…"
    }
}
