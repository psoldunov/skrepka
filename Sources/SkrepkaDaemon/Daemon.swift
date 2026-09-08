import Foundation
import Logging
import NIOPosix
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

/// The Linux daemon: the composition root, and nothing else.
///
/// The same job `AppCoordinator` does on macOS, and worth reading that file
/// beside this one — the two should stay recognisably the same program. What
/// this composes:
///
/// ```
/// ClipboardBackend (Phase 5)
///    → ClipboardWatcher + CaptureRules   ported, unchanged
///    → SQLiteHistoryStore                the Linux HistoryStoring (Phase 4)
///    → SyncRuntime / PeerLink            SkrepkaSync (Phases 1–2)
///    → AvahiDiscovery                    Phase 6
/// ```
///
/// The middle two are the ported code. Only the ends are new, and that is the
/// payoff for Phase 4.
///
/// ## Why an actor rather than the macOS coordinator's shape
///
/// `SyncCoordinator` is `@MainActor @Observable`, because a SwiftUI settings
/// pane reads it. There is no main actor worth having here and nothing
/// observing, so this is an ordinary actor. What does carry across is the
/// *serialisation*: bring-up, tear-down and the settings that restart a
/// listener must not interleave, and actor re-entrancy across an `await` is the
/// same hazard main-actor statement-ordering was. ``enqueue(_:)`` is the answer,
/// and it is the coordinator's `enqueueLifecycle` under another name.
public actor Daemon {
    /// How long an inbound pairing waits for somebody to answer it.
    ///
    /// Bounded, and the bound is the point. A proposal parks a task inside the
    /// responder, and on a daemon nobody is watching there may be no client to
    /// answer — so the wait ends by itself and the answer is `false`. A dropped
    /// continuation is a task suspended for the life of the process, and a
    /// pairing accepted because nobody said no is worse.
    public static let defaultPairingAnswerTimeout: Duration = .seconds(120)

    /// How long the pairing listener stays open when a client does not say.
    public static let defaultPairingWindow: Duration = .seconds(5 * 60)

    /// The longest window ``openPairing(for:)`` will open, whatever a caller
    /// asks for.
    ///
    /// The window is the only moment a stranger on the LAN can complete a
    /// handshake with this machine, and the bus takes the duration as a raw
    /// `u` — `busctl call … OpenPairing u 4294967295` would otherwise leave the
    /// accept-anything listener up for about a hundred and thirty years, which
    /// contradicts the invariant ``openPairing(for:)`` documents.
    public static let maximumPairingWindow: Duration = .seconds(30 * 60)

    /// How long the whole dial-and-pair in ``pair(withFingerprint:)`` may take.
    ///
    /// Generous for a LAN, and needed because neither `SyncClient.connect` nor
    /// `SyncInitiator.pair(at:)` carries a deadline of its own. The daemon's
    /// bus connection dispatches calls serially, so a peer that completes the
    /// TCP connect and then says nothing would hang every subsequent `History`,
    /// `Copy`, `Diagnostics` and `SyncNow` with it.
    public static let pairDialTimeout: Duration = .seconds(30)

    /// Where the listeners bind.
    ///
    /// Every interface, because the whole point is a peer on the LAN. The
    /// pinned listener is safe there by construction — its TLS callback accepts
    /// only certificates the user has already approved — and the pairing one is
    /// open only while a user has asked for it and only for as long as
    /// ``defaultPairingWindow``.
    static let listenHost = "0.0.0.0"

    public let options: DaemonOptions
    let environment: [String: String]
    let logger: Logger
    let store: SQLiteHistoryStore
    let trust: FileTrustStore
    let displayName: String

    /// How long this daemon waits for an answer to a pairing proposal.
    ///
    /// A stored property rather than the static alone so a test can prove the
    /// refusal default without sleeping for two minutes. Production never
    /// passes it.
    let pairingAnswerTimeout: Duration

    // MARK: - Sync state

    var runtime: SyncRuntime?
    var group: MultiThreadedEventLoopGroup?
    var syncServer: SyncServer?
    var pairingServer: SyncServer?

    /// The loop that takes connections off ``syncServer``.
    ///
    /// Three separate handles rather than one array, because the three have
    /// three lifetimes and one array made every teardown cancel all of them:
    /// ``performRestartSyncListener()`` owns this one, ``performClosePairing()`` owns
    /// ``pairingAcceptTask``, and only ``performStop()`` owns all three. The
    /// array version cancelled the pairing loop whenever the paired set
    /// changed, leaving `pairingServer` bound and advertised with nothing
    /// accepting on it.
    var syncAcceptTask: Task<Void, Never>?

    /// The loop that takes connections off ``pairingServer``.
    var pairingAcceptTask: Task<Void, Never>?

    /// One task per inbound connection, keyed so each can remove its own entry
    /// when it finishes. Unkeyed, this grew by one entry per connection for the
    /// life of the process.
    var connectionTasks: [UUID: Task<Void, Never>] = [:]

    var pairingExpiry: Task<Void, Never>?
    var pairingWindowEnds: Date?

    var discovery: AvahiDiscovery?
    var browseTask: Task<Void, Never>?

    /// The loop that reports the entry group failing after it was published.
    ///
    /// Stored and replaced rather than started and forgotten, the same shape as
    /// ``syncAcceptTask``. ``publishAdvertisement()`` runs on every `.ready` and
    /// on every republish — a pairing window opening or closing is one — so the
    /// fire-and-forget version left one live watcher per successful publish, and
    /// a single collision then called ``advertisementLost(_:)`` once for each of
    /// them.
    var advertisementFailureTask: Task<Void, Never>?
    var isPublished = false
    var responderProblem: String?

    /// One system-bus connection for the whole process.
    ///
    /// Shared by `AvahiDiscovery` and `ClockCheck` rather than one each: two
    /// connections to a bus get two unique names, and a signal directed at one
    /// does not reach the other — which is exactly how avahi delivers every
    /// browser and entry-group signal. See ``SkrepkaIPC/BusSession``.
    let systemBus = BusSession(bus: .system)

    /// What `ClockCheck` last found, or nil before the first diagnostics read.
    var clockFinding: ClockCheck.Finding?

    var links: [SyncDeviceID: PeerLink] = [:]
    var progress: [SyncDeviceID: PeerProgress] = [:]
    var sighted: [SyncDeviceID: Sighting] = [:]

    /// Pairings waiting for an answer, by device. One entry per peer, because
    /// a peer that dials twice while the first is unanswered is retrying.
    var pending: [SyncDeviceID: PendingPairing] = [:]

    /// Content this device learned from a peer in the last few seconds, so a
    /// live push written to the clipboard is not captured and pushed back.
    var recentlyReceived = RecentHashes()

    // MARK: - Clipboard state

    var clipboard: ClipboardBackend.Running?
    var watcher: ClipboardWatcher?
    var captureTask: Task<Void, Never>?
    var sessionRestarts = 0
    /// Whether a clipboard backend has ever started in this process.
    ///
    /// What tells "the compositor went away and will come back" apart from
    /// "this machine has no display" — see ``scheduleSessionRestart(attempt:)``,
    /// where the two get different retry policies.
    var hasEverCaptured = false
    var lastCapturedAt: Date?
    var sessionReport: SessionProbe.Report?

    // MARK: - Bookkeeping

    var lifecycleTail: Task<Void, Never>?
    var historyObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var pairingObservers: [UUID: AsyncStream<PendingPairing>.Continuation] = [:]
    var isStopping = false

    public init(
        options: DaemonOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger = Logger(label: "skrepka.daemon"),
        pairingAnswerTimeout: Duration = Daemon.defaultPairingAnswerTimeout
    ) throws {
        self.options = options
        self.environment = environment
        self.logger = logger
        self.pairingAnswerTimeout = pairingAnswerTimeout
        displayName =
            options.displayName.isEmpty
            ? DeviceName.current(environment: environment) : options.displayName
        store = try SQLiteHistoryStore(location: options.storeURL(environment: environment))
        trust = FileTrustStore(
            url: options.deviceKeyURL(environment: environment),
            peers: store
        )
    }

    /// The store, for the D-Bus service that shares it.
    ///
    /// `nonisolated` because it is an immutable `let` to an actor: reaching it
    /// costs no hop, and every method on it is isolated in its own right.
    public nonisolated var historyStore: SQLiteHistoryStore { store }

    // MARK: - Serialising the lifecycle

    /// Runs `work` after everything already queued, and returns a handle to it.
    ///
    /// The daemon's own `enqueueLifecycle`. Bring-up, tear-down, opening the
    /// pairing window and restarting a listener all mutate the same half-dozen
    /// properties across several awaits, and an actor guarantees only that one
    /// of them runs at a time between suspension points — not that one finishes
    /// before the next begins.
    ///
    /// **Anything already inside queued work calls the `perform…` half
    /// directly.** Awaiting this from within it waits for itself.
    @discardableResult
    func enqueue(_ work: @escaping @Sendable (Daemon) async -> Void) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await work(self)
        }
        lifecycleTail = task
        return task
    }

    /// ``enqueue(_:)`` for work that answers with something, or throws.
    ///
    /// The queue itself stays `Task<Void, Never>`: it exists to order the
    /// lifecycle, and whether one piece of that work failed is the business of
    /// whoever awaits the returned handle, not of the piece queued behind it.
    ///
    /// A separate name rather than an overload of ``enqueue(_:)``: the two
    /// closure types differ only in `throws` and a return, which is exactly the
    /// shape that makes an existing `enqueue { await $0.performStop() }` a
    /// coin-toss for the type checker.
    func enqueueAnswering<Answer: Sendable>(
        _ work: @escaping @Sendable (Daemon) async throws -> Answer
    ) -> Task<Answer, any Error> {
        let previous = lifecycleTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await work(self)
        }
        // `try?` rather than a handled error: the tail's only job is to make
        // the next piece of queued work start after this one has finished, and
        // the error is delivered — unswallowed — to the caller awaiting `task`.
        lifecycleTail = Task { _ = try? await task.value }
        return task
    }
}

/// What one paired peer's link is doing, for the peer list.
struct PeerProgress: Sendable, Hashable {
    var state = "idle"
    var name: String?
    var platform: PeerPlatform = .unknown
    var lastSyncedAt: Date?
}

/// A peer seen on the network, with the record it advertised.
struct Sighting: Sendable {
    let peer: DiscoveredPeer
    let advertisement: PeerAdvertisement
}
