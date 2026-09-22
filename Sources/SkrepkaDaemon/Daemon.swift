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

    /// Changed only by ``performApplySettings(_:)``, on the lifecycle queue.
    let settingsFile: DaemonSettingsFile
    var settings: DaemonSettings

    /// The file-size limit every sync runtime this daemon builds reads, kept
    /// in step with ``settings`` — see `SkrepkaSync.FileSyncLimit`. One for the
    /// process, so a sync restart does not reset it.
    let fileSync: FileSyncPolicy

    /// Where fetches report their progress, for the `TransfersChanged` signal.
    /// One for the process, so the signal pump outlives a sync restart.
    let transfers = TransferMonitor()

    /// How long this daemon waits for an answer to a pairing proposal.
    ///
    /// A stored property rather than the static alone so a test can prove the
    /// refusal default without sleeping for two minutes. Production never
    /// passes it.
    let pairingAnswerTimeout: Duration

    // MARK: - Sync state

    var runtime: SyncRuntime?
    /// Bumped whenever the sync stack starts or stops. See `Daemon+SyncGeneration.swift`.
    var syncGeneration = 0
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
    /// a single collision then called ``advertisementLost(_:generation:)`` once
    /// for each of them.
    var advertisementFailureTask: Task<Void, Never>?

    /// Which watcher the live one is.
    ///
    /// Cancelling the previous task does not stop a failure it has *already*
    /// taken off the stream from landing, so a loss belonging to a replaced
    /// watcher could clear ``isPublished`` and set ``responderProblem`` for the
    /// advertisement that succeeded it — a healthy republish reported as broken
    /// by `skrepka doctor` for as long as the daemon runs. Stamping the watcher
    /// and comparing the stamp is how ``advertisementLost(_:generation:)``
    /// tells the two apart, the same shape
    /// `AvahiDiscovery.serverWatchGeneration` and `BusSession.epoch` use.
    var advertisementGeneration = 0
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

    /// What peers pushed here, so a live push written to the clipboard is not
    /// captured and pushed back, and the rule that concealed content never
    /// leaves.
    var livePushGate = LivePushGate()

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
    /// A well-formed clipboard handoff proves the GNOME Shell extension can
    /// cover native Wayland copies that the XFIXES fallback cannot see.
    var hasReceivedClipboardSubmission = false
    var sessionReport: SessionProbe.Report?

    // MARK: - Bookkeeping

    var lifecycleTail: Task<Void, Never>?
    var retentionSweepTask: Task<Void, Never>?
    var historyObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var pairingObservers: [UUID: AsyncStream<PendingPairing>.Continuation] = [:]
    var isStopping = false

    /// - Parameter peers: where paired-device records go. Nil means the SQLite
    ///   store beside the history, which is the only thing production passes —
    ///   the parameter exists so a test can hand over a store whose
    ///   `savePairedPeer` throws, which is the difference between
    ///   ``answerPairing(deviceID:accept:)`` reporting a pairing and lying
    ///   about one, and cannot be induced on a real database.
    public init(
        options: DaemonOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger = Logger(label: "skrepka.daemon"),
        pairingAnswerTimeout: Duration = Daemon.defaultPairingAnswerTimeout,
        peers: (any PairedDeviceStoring)? = nil
    ) throws {
        self.options = options
        self.environment = environment
        self.logger = logger
        self.pairingAnswerTimeout = pairingAnswerTimeout
        displayName =
            options.displayName.isEmpty
            ? DeviceName.current(environment: environment) : options.displayName
        settingsFile = DaemonSettingsFile(url: options.settingsURL(environment: environment))
        settings = settingsFile.load(logger: logger)
        fileSync = FileSyncPolicy(maximumBytes: settings.fileSync.maximumBytes)
        store = try SQLiteHistoryStore(
            location: options.storeURL(environment: environment),
            retention: settings.retentionPolicy
        )
        trust = FileTrustStore(
            url: options.deviceKeyURL(environment: environment),
            peers: peers ?? store
        )
    }

    /// The store, for the D-Bus service that shares it.
    ///
    /// `nonisolated` because it is an immutable `let` to an actor: reaching it
    /// costs no hop, and every method on it is isolated in its own right.
    public nonisolated var historyStore: SQLiteHistoryStore { store }
}
