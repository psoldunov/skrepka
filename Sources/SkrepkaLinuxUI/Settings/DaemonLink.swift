import Foundation
import SkrepkaIPC
import Synchronization

/// The Settings window's side of the session bus: the actions it sends, a poll
/// of the peer list, and a watch for peers that dial in.
///
/// ## One call at a time, in the order asked
///
/// The daemon answers bus calls one at a time, and a `PairWith` can spend its
/// whole thirty-second dial deadline before answering. A poll sent meanwhile
/// would wait behind it, time out after ten seconds — and a timeout invalidates
/// the bus session, closing the very connection the dial's answer was coming
/// back on. So every call goes through one queue, consumed by one task, one
/// command at a time.
///
/// The queue is an `AsyncStream`, and the window writes to it synchronously
/// from its own thread — ``perform(_:)`` and ``refreshIfIdle()`` are
/// `nonisolated` for exactly that. A `Task` per action would reach this actor
/// in no particular order, and "turn pairing on, then close the window" could
/// then close first and leave a pairing window open behind a window that is
/// gone.
///
/// A poll that finds anything queued is dropped rather than added: the next is
/// two seconds away, and every action refreshes the list when it finishes.
///
/// Everything it learns goes out through `report`, as ``SyncEvent`` values —
/// on the concurrency pool, never the window's thread. The window reads them
/// from a ``MainLoopInbox``.
public actor DaemonLink {
    public typealias Connect = @Sendable () async throws -> any SyncDaemon
    public typealias Report = @Sendable (SyncEvent) -> Void

    /// What the window asked of the link, in the order it asked.
    enum Command: Sendable {
        case perform(SyncAction)
        case refresh
        /// Another pane's call — History's, Diagnostics' — queued behind the
        /// Sync pane's so it cannot time out behind a dial either. It reports
        /// for itself.
        case job(@Sendable () async -> Void)
        case shutdown
    }

    private let connect: Connect
    private let report: Report
    private let commands: AsyncStream<Command>
    private nonisolated let sink: AsyncStream<Command>.Continuation
    /// Commands queued or running. Behind a `Mutex` rather than on the actor
    /// because the window counts one in synchronously, from its own thread.
    private nonisolated let backlog = Mutex(0)
    private var consumer: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var watching: Task<Void, Never>?
    /// Whether the pairing window is one this link opened and nobody has
    /// closed since — the one the window has to close when it goes away.
    private var ownsPairingWindow = false
    /// Devices with a proposal this link has seen and nobody has answered
    /// through it: codes it dialled for, and peers that dialled in. Refused on
    /// the way out, so a window that closes — mid-dial, with a code on screen,
    /// or with a peer dialling in while it winds up — does not leave another
    /// machine waiting out its timeout. The link sees every proposal and every
    /// answer, which is why this is kept here rather than read off the prompt.
    private var unanswered: Set<String> = []

    public init(connect: @escaping Connect, report: @escaping Report) {
        self.connect = connect
        self.report = report
        (commands, sink) = AsyncStream<Command>.makeStream()
    }

    /// Starts working through the queue, polling, and watching for pairing
    /// requests. Idempotent. Commands sent before it waited in the queue.
    ///
    /// - Parameter interval: How often to read the peer list, or nil for never
    ///   — which is for tests that need to know every call that is made.
    public func start(
        pollingEvery interval: Duration? = .seconds(2),
        retryingAfter retry: Duration = .seconds(2)
    ) {
        guard consumer == nil else { return }
        let commands = commands
        consumer = Task { [weak self] in
            await self?.consume(commands)
        }
        if let interval { startPolling(every: interval) }
        watching = Task { [weak self] in
            await self?.watchPairingRequests(retryAfter: retry)
        }
    }

    private func startPolling(every interval: Duration) {
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshIfIdle()
                // Cancellation is the only way this throws, and it is how the
                // loop is meant to end — the `while` sees it next.
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Queues `action`. Its outcome and the peer list read straight afterwards
    /// arrive as one ``SyncEvent/finished(_:_:refreshed:)``.
    public nonisolated func perform(_ action: SyncAction) {
        enqueue(.perform(action))
    }

    /// Queues `job` behind everything already asked, for a pane other than
    /// Sync. Nothing is reported for it; the job reports its own outcome.
    public nonisolated func run(_ job: @escaping @Sendable () async -> Void) {
        enqueue(.job(job))
    }

    /// Queues a read of the peer list, unless something is already queued.
    public nonisolated func refreshIfIdle() {
        guard backlog.withLock({ $0 }) == 0 else { return }
        enqueue(.refresh)
    }

    /// Finishes what was queued before it, refuses every proposal it has seen
    /// that nobody answered, closes a pairing window this link opened, and
    /// stops. Reports ``SyncEvent/shutDown`` last. Needs
    /// ``start(pollingEvery:retryingAfter:)`` to have run, or there is nothing
    /// working through the queue to reach it.
    ///
    /// The pairing window is closed rather than left to expire because it is
    /// the one moment a stranger on the network can complete a handshake with
    /// this machine, and with this window gone there is nobody to answer one.
    public func shutdown() async {
        enqueue(.shutdown)
        await consumer?.value
    }

    private nonisolated func enqueue(_ command: Command) {
        backlog.withLock { $0 += 1 }
        sink.yield(command)
    }

    // MARK: - The queue

    private func consume(_ commands: AsyncStream<Command>) async {
        for await command in commands {
            let isLast = await handle(command)
            if isLast { return }
        }
    }

    /// Runs one command. Answers whether it was the last.
    private func handle(_ command: Command) async -> Bool {
        let event: SyncEvent
        switch command {
        case .perform(let action):
            event = await Self.perform(action, connect: connect)
        case .refresh:
            do {
                event = .refreshed(try await connect().peers())
            } catch {
                event = .unreachable(SyncFailure(describing: error))
            }
        case .job(let job):
            await job()
            backlog.withLock { $0 -= 1 }
            return false
        case .shutdown:
            await windUp()
            backlog.withLock { $0 -= 1 }
            report(.shutDown)
            return true
        }
        // Settled before it is reported, so whoever reads the report and asks
        // for a refresh finds the queue already empty.
        settle(after: event)
        backlog.withLock { $0 -= 1 }
        report(event)
        return false
    }

    private func windUp() async {
        polling?.cancel()
        watching?.cancel()
        sink.finish()
        // Best effort, and uninteresting when it fails: the daemon closes the
        // window when it expires, and refuses a code nobody answers when that
        // runs out. A proposal that has already expired is refused anyway —
        // the daemon answers that nothing is waiting, which costs one call.
        guard ownsPairingWindow || !unanswered.isEmpty, let daemon = try? await connect() else { return }
        for deviceID in unanswered.sorted() {
            _ = try? await daemon.confirmPairing(deviceID: deviceID, accept: false)
        }
        if ownsPairingWindow {
            _ = try? await daemon.closePairing()
        }
        unanswered = []
        ownsPairingWindow = false
    }

    private func settle(after event: SyncEvent) {
        switch event {
        case .finished(.openPairingWindow, .opened, _):
            ownsPairingWindow = true
        case .finished(.closePairingWindow, .answered(let document), _) where document.ok:
            ownsPairingWindow = false
        case .finished(.pair, .proposed(let proposal), _):
            unanswered.insert(proposal.deviceID)
        case .finished(.answer(let deviceID, _), _, _):
            unanswered.remove(deviceID)
        default:
            break
        }
        // A window that expired, or that somebody else closed, is not this
        // link's to close any more.
        switch event {
        case .refreshed(let document), .finished(_, _, refreshed: .some(let document)):
            if document.pairingPort == nil { ownsPairingWindow = false }
        default:
            break
        }
    }

    // MARK: - The calls

    private static func perform(_ action: SyncAction, connect: Connect) async -> SyncEvent {
        let daemon: any SyncDaemon
        do {
            daemon = try await connect()
        } catch {
            return .finished(action, .failed(SyncFailure(describing: error)), refreshed: nil)
        }
        let result = await run(action, on: daemon)
        // Discarded deliberately: a failed read leaves the window with the
        // list it had, and the next poll reports the failure itself.
        let refreshed = try? await daemon.peers()
        return .finished(action, result, refreshed: refreshed)
    }

    private static func run(_ action: SyncAction, on daemon: any SyncDaemon) async -> ActionResult {
        do {
            switch action {
            case .openPairingWindow:
                // Zero asks for the daemon's own default window, so the length
                // is decided in one place.
                return .opened(try await daemon.openPairing(seconds: 0))
            case .closePairingWindow:
                return .answered(try await daemon.closePairing())
            case .pair(let deviceID):
                return .proposed(try await daemon.pairWith(deviceID: deviceID))
            case .answer(let deviceID, let accept):
                return .answered(try await daemon.confirmPairing(deviceID: deviceID, accept: accept))
            case .unpair(let deviceID):
                return .answered(try await daemon.unpair(fingerprint: deviceID))
            case .setLivePush(let deviceID, let isOn):
                let choice = isOn ? PeerDocument.LivePushChoiceName.on : PeerDocument.LivePushChoiceName.off
                return .answered(try await daemon.setLivePush(device: deviceID, choice: choice))
            case .syncNow:
                return .answered(try await daemon.syncNow())
            }
        } catch {
            return .failed(SyncFailure(describing: error))
        }
    }

    /// Forwards every incoming proposal, reconnecting whenever the stream ends.
    ///
    /// Outside the queue on purpose. Subscribing is a call to the bus itself,
    /// not to the daemon, so it cannot wait behind a dial — and a proposal
    /// arriving mid-dial is exactly the one that must not be missed. Every
    /// wait here is a suspension, so the loop holds the actor only while it
    /// forwards.
    private func watchPairingRequests(retryAfter: Duration) async {
        while !Task.isCancelled {
            // Both discarded deliberately: an unreachable daemon is reported by
            // the poll, once and in words, and this only has to try again.
            if let daemon = try? await connect(), let requests = try? await daemon.pairingRequests() {
                for await proposal in requests {
                    forward(proposal)
                }
            }
            // A stream that ended means its connection did. Cancellation cuts
            // the wait short, and the `while` then ends the loop.
            try? await Task.sleep(for: retryAfter)
        }
    }

    /// Reports a proposal, and remembers one a peer started until it is
    /// answered. An outgoing one on the signal is another client's dial —
    /// `skrepka pair --peer` — and not this link's to refuse.
    private func forward(_ proposal: PairingProposalDocument) {
        if proposal.direction == PairingProposalDocument.Direction.incoming {
            unanswered.insert(proposal.deviceID)
        }
        report(.pairingRequested(proposal))
    }
}
