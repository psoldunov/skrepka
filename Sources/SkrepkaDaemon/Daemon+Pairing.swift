import Foundation
import Logging
import SkrepkaIPC
import SkrepkaSync

extension Daemon {
    /// Opens the pairing listener for `duration`, and advertises its port.
    ///
    /// A second listener because the two cannot be one. The pinned listener's
    /// TLS callback accepts only certificates the user has already approved,
    /// and pairing is by construction a connection from a device with nothing
    /// pinned — so a listener that accepted both would have to accept any
    /// well-formed leaf on the port that also serves history.
    ///
    /// Bounded, always. The window is the only moment a stranger on the LAN can
    /// complete a handshake with this machine at all, so it closes on its own
    /// whether or not anyone remembers to — and never for longer than
    /// ``Daemon/maximumPairingWindow``, whatever the caller asked for.
    ///
    /// Queued like every other lifecycle step. Unqueued it mutated
    /// `pairingServer` and `pairingWindowEnds` across two awaits, so an
    /// `OpenPairing` arriving while the expiry task was inside
    /// `performClosePairing`'s `await pairingServer?.stop()` bound a second
    /// accept-anything listener that the resuming close then orphaned —
    /// unreachable by `closePairing`, by the expiry task and by `stop()`.
    public func openPairing(for duration: Duration) async throws -> PairingWindowDocument {
        let window = min(duration, Self.maximumPairingWindow)
        return try await enqueueAnswering { try await $0.performOpenPairing(for: window) }.value
    }

    func performOpenPairing(for duration: Duration) async throws -> PairingWindowDocument {
        guard let runtime else { throw PairingWindowError.syncIsOff }
        if let server = pairingServer, pairingWindowEnds != nil {
            // Already open. Extending it rather than refusing, because a second
            // `skrepka pair` while the first window is up is a user retrying,
            // not a mistake.
            let ends = scheduleWindowClose(after: duration)
            return PairingWindowDocument(port: UInt16(server.port), expiresAt: ends)
        }
        let server = try await SyncServer.start(
            identity: runtime.certificate,
            policy: .pairing,
            host: Self.listenHost,
            group: runtime.group
        )
        // Re-checked after the await: `stop()` may have run while the listener
        // was binding, and a pairing port left open on a stopping daemon is the
        // one thing that must not survive.
        guard !isStopping, self.runtime != nil else {
            await server.stop()
            throw PairingWindowError.syncIsOff
        }
        pairingServer = server
        pairingAcceptTask = pairingAcceptLoop(on: server)
        let ends = scheduleWindowClose(after: duration)
        await republishAdvertisement()
        return PairingWindowDocument(port: UInt16(server.port), expiresAt: ends)
    }

    /// Closes the window early. Idempotent.
    public func closePairing() async {
        await enqueue { await $0.performClosePairing() }.value
    }

    /// Tears the pairing half down, and only the pairing half: the pinned
    /// listener and every live connection have their own task handles.
    func performClosePairing() async {
        pairingExpiry?.cancel()
        pairingExpiry = nil
        pairingWindowEnds = nil
        pairingAcceptTask?.cancel()
        pairingAcceptTask = nil
        guard pairingServer != nil else { return }
        await pairingServer?.stop()
        pairingServer = nil
        await republishAdvertisement()
    }

    /// Arms the expiry, and answers when the window now ends.
    ///
    /// The later of the two deadlines wins. Overwriting it unconditionally
    /// meant re-opening with a shorter duration promised the caller the longer
    /// expiry while the listener actually closed on the shorter one.
    @discardableResult
    private func scheduleWindowClose(after duration: Duration) -> Date {
        pairingExpiry?.cancel()
        let requested = Date().addingTimeInterval(duration.seconds)
        let ends = max(pairingWindowEnds ?? requested, requested)
        pairingWindowEnds = ends
        pairingExpiry = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, ends.timeIntervalSinceNow)))
            } catch {
                // Cancelled by a later window or by tear-down; whoever
                // cancelled owns closing it.
                return
            }
            await self?.closePairing()
        }
        return ends
    }

    private func pairingAcceptLoop(on server: SyncServer) -> Task<Void, Never> {
        Task { [weak self] in
            while let connection = await server.nextConnection() {
                guard !Task.isCancelled else { return }
                await self?.serve(connection)
            }
        }
    }

    // MARK: - Answering a proposal

    /// Parks a proposal until somebody answers it, or until it expires.
    ///
    /// **Refusal is the default**, and that is the whole reason this is bounded
    /// rather than an unresumed continuation. There may be no client attached:
    /// `skrepkad` runs under systemd and `skrepka pair` may never be typed. A
    /// pairing accepted because nobody was watching is the outcome this must
    /// not have.
    func confirmPairing(_ proposal: PairingProposal, direction: String) async -> Bool {
        let (answers, sink) = AsyncStream<Bool>.makeStream()
        let deviceID = proposal.peer.deviceID
        let pairing = PendingPairing(
            proposal: proposal,
            direction: direction,
            expiresAt: Date().addingTimeInterval(pairingAnswerTimeout.seconds),
            sink: sink
        )
        // A peer that dials twice while the first proposal is unanswered is
        // retrying. The older one is expired rather than left parked, so its
        // task unwinds and its connection closes.
        pending[deviceID]?.expire()
        pending[deviceID] = pairing
        for observer in pairingObservers.values { observer.yield(pairing) }

        let accepted = await Self.firstAnswer(answers, timeout: pairingAnswerTimeout)
        forget(deviceID, proposalID: pairing.id)
        if accepted { await pairedSetMayHaveChanged() }
        return accepted
    }

    /// Drops a proposal, unless a newer one from the same device has already
    /// taken its place. See ``PendingPairing/id``.
    func forget(_ deviceID: SyncDeviceID, proposalID: UUID) {
        guard pending[deviceID]?.id == proposalID else { return }
        pending[deviceID] = nil
    }

    /// The answer, or `false` when the deadline passes first.
    ///
    /// `nonisolated static` so waiting for a human does not hold the actor: a
    /// proposal parked for two minutes while the daemon could not answer
    /// `skrepka list` would be a worse bug than the one this is preventing.
    private nonisolated static func firstAnswer(
        _ answers: AsyncStream<Bool>,
        timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await answer in answers { return answer }
                // The stream finished without an answer, which is what
                // `PendingPairing.expire()` does. Refusal.
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }
    }

    /// Answers a proposal that is waiting, and says what that meant.
    ///
    /// Answers an ``ActionDocument`` rather than a bare `Bool` because refusing
    /// an *outgoing* proposal has a consequence the user has to be told about,
    /// and the sentence belongs here rather than in one client: the daemon
    /// serves `skrepka`, the Phase 8 GNOME extension and anything else on the
    /// session bus, and each of them would otherwise have to know the
    /// asymmetry — see ``PairError/oneSidedWarning``.
    ///
    /// **Accepting an outgoing proposal records the peer before it answers.**
    /// The dialling side has already finished its exchange by the time a human
    /// reads the short authentication string, so this side writes the record
    /// here or nowhere — and answering first meant a `savePairedPeer` that
    /// threw left the client having printed "paired" for a pairing this device
    /// did not record while the far side did. That is the one-sided state
    /// ``PairError/oneSidedWarning`` exists to report, reached from the other
    /// direction, so the failure says the same sentence.
    public func answerPairing(deviceID: SyncDeviceID, accept: Bool) async -> ActionDocument {
        guard let pairing = pending[deviceID] else {
            return .refused("no pairing is waiting for that device", subject: deviceID.hex)
        }
        guard accept else {
            pairing.answer(false)
            return Self.refusal(direction: pairing.direction, subject: deviceID.hex)
        }
        guard pairing.direction == PairingDirection.outgoing else {
            // Inbound: `SyncResponder` writes the record itself once the
            // proposal it is parked on answers yes, so there is nothing to save
            // here — see ``confirmPairing(_:direction:)``, which is what it is
            // parked on.
            pairing.answer(true)
            return .succeeded("paired", subject: deviceID.hex)
        }
        do {
            try await trust.savePairedPeer(pairing.peer)
        } catch {
            logger.error(
                "could not record a paired device",
                metadata: ["error": .string(String(describing: error))]
            )
            pairing.answer(false)
            return .refused(
                "this device could not be recorded as paired. \(PairError.oneSidedWarning)",
                subject: deviceID.hex
            )
        }
        pairing.answer(true)
        await pairedSetMayHaveChanged()
        return .succeeded("paired", subject: deviceID.hex)
    }

    /// What a refusal says, which depends on which way the proposal ran.
    private static func refusal(direction: String, subject: String) -> ActionDocument {
        guard direction == PairingDirection.outgoing else {
            // Inbound: the far side is still inside its own dial and this
            // refusal is the answer it gets, so neither machine records the
            // other. Nothing to warn about.
            return .succeeded("refused", subject: subject)
        }
        // The journal entry is written by ``completeOutgoing(_:proposalID:accepted:)``,
        // which is also where an outgoing proposal nobody answered at all ends
        // up — one line for both, rather than one here and none for the timeout.
        return .succeeded("refused. \(PairError.oneSidedWarning)", subject: subject)
    }

    /// Every proposal that arrives from now on.
    public func pairingProposals() -> AsyncStream<PairingProposalDocument> {
        let (stream, continuation) = AsyncStream<PendingPairing>.makeStream()
        let id = UUID()
        pairingObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePairingObserver(id) }
        }
        // A proposal already waiting is replayed, so a client that starts after
        // a peer dialled still sees it. Without this, `skrepka pair` run one
        // second late waits for a proposal that has already arrived.
        for pairing in pending.values { continuation.yield(pairing) }
        return AsyncStream { outer in
            let task = Task {
                for await pairing in stream { outer.yield(pairing.document) }
                outer.finish()
            }
            outer.onTermination = { _ in task.cancel() }
        }
    }

    func removePairingObserver(_ id: UUID) {
        pairingObservers[id] = nil
    }

    /// Proposals waiting right now, for a client that polls rather than
    /// subscribes.
    public func pendingProposals() -> [PairingProposalDocument] {
        pending.values.map(\.document).sorted { $0.fingerprint < $1.fingerprint }
    }
}

/// Why the pairing window could not be opened.
public enum PairingWindowError: Error, Sendable, CustomStringConvertible {
    /// The daemon is running with `--no-sync`, so there is no runtime to pair
    /// with.
    case syncIsOff

    public var description: String {
        switch self {
        case .syncIsOff:
            "sync is turned off on this device, so it cannot pair. Restart skrepkad without --no-sync."
        }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the `Date` arithmetic the IPC documents
    /// need.
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
