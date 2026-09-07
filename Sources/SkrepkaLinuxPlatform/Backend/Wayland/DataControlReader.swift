import Foundation
import SkrepkaCore

/// A ``SkrepkaCore/ClipboardSource`` over either Wayland data-control protocol.
///
/// ## One reader, not two
///
/// The phase plan named `ExtDataControlReader` and `WlrDataControlReader` as
/// separate deliverables. They collapsed into this, and the reason is a
/// measurement rather than a preference: normalising the `ext_data_control_`
/// and `zwlr_data_control_` prefixes off the two vendored protocol XML files
/// leaves **37 identical entries each** — every interface, request, event and
/// argument. `wayland-scanner` emits 665 lines of header from either.
///
/// Two readers would therefore be one implementation typed out twice, and the
/// deprecated spelling is the one with hardware behind it — a bug fixed in the
/// current one would sit unfixed where it actually bites. What differs between
/// the protocols is the C symbol names, and that is exactly what
/// ``DataControlProtocolBinding`` and its two conformers isolate. The two
/// named readers survive as ``ext`` and ``wlr``.
///
/// ## Event driven, so nothing polls
///
/// ``changeNotifications()`` returns a stream, so `ClipboardWatcher` runs no
/// timer at all. That is the whole reason `ClipboardSource` carries both
/// shapes: macOS has no clipboard notification and is stuck at a 200 ms tick,
/// and Wayland has had one all along.
public actor DataControlReader: ClipboardSource {
    /// How long ``start()`` waits for the session to connect and read the
    /// clipboard's current contents.
    ///
    /// Generous, because it covers a compositor round trip plus a first
    /// capture that may be a large image, and because the alternative to
    /// waiting is worse: `ClipboardWatcher` baselines on the first change count
    /// it reads, so starting it before the session has one turns whatever was
    /// already on the clipboard into a fresh capture.
    static let startupTimeout: Duration = .seconds(3)
    private static let startupPollInterval: Duration = .milliseconds(10)

    public enum StartError: Error, Equatable {
        /// The process could not allocate the wakeup pipe.
        case outOfFileDescriptors
        /// The session ran and stopped, with the reason it gave.
        case sessionFailed(String)
        /// Nothing had gone wrong within ``startupTimeout``, and nothing had
        /// finished either.
        case timedOut
    }

    private let kind: LinuxClipboardBackendKind
    private let displayName: String?
    private let state = LinuxClipboardState()
    private let commands = CommandQueue<DataControlSession.Command>()
    private var wakeup: WakePipe?
    private var thread: Thread?
    private var notifications: AsyncStream<Void>?

    /// - Parameter displayName: which compositor to connect to, or nil to let
    ///   libwayland read `WAYLAND_DISPLAY`. An absolute socket path is used
    ///   as-is and needs no `XDG_RUNTIME_DIR`.
    public init(_ kind: LinuxClipboardBackendKind, displayName: String? = nil) {
        self.kind = kind
        self.displayName = displayName
    }

    /// `ext-data-control-v1`, the current protocol.
    public static func ext() -> DataControlReader { DataControlReader(.extDataControl) }
    /// `zwlr-data-control-unstable-v1`, deprecated and still the only one some
    /// compositors advertise.
    public static func wlr() -> DataControlReader { DataControlReader(.wlrDataControl) }

    /// Connects, and returns once the clipboard's current contents have been
    /// read.
    ///
    /// Explicit rather than lazy because `ClipboardSource` has no lifecycle and
    /// the session owns a thread: something has to say when it starts and when
    /// it stops, and hiding that inside the first `changeCount()` would make
    /// every caller pay a three-second timeout for a mistake in configuration.
    public func start() async throws {
        guard thread == nil else { return }
        guard let wakeup = WakePipe() else { throw StartError.outOfFileDescriptors }
        self.wakeup = wakeup

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        notifications = stream

        // Everything crossing into the thread is Sendable; the session itself
        // is built inside and never leaves. That is what makes a non-Sendable
        // class holding a `wl_display` safe here without a single unchecked
        // conformance.
        let kind = self.kind
        let state = self.state
        let commands = self.commands
        let displayName = self.displayName
        let thread = Thread {
            let binding: any DataControlProtocolBinding =
                kind == .extDataControl ? ExtDataControlBinding() : WlrDataControlBinding()
            DataControlSession(
                binding: binding, state: state, notify: continuation, displayName: displayName
            )
            .run(commands: commands, wakeup: wakeup)
        }
        thread.name = "dev.soldunov.skrepka.wayland-clipboard"
        self.thread = thread
        thread.start()

        try await waitForBaseline()
    }

    /// Polls the shared state until the session has read the clipboard once.
    ///
    /// A poll rather than a continuation resumed from the loop thread: the
    /// state is already behind a `Mutex` that the loop writes under, and adding
    /// a continuation to it would mean a second thing to get right on the exit
    /// path — a session that fails between the check and the wait would leave
    /// the caller suspended forever. Ten milliseconds of latency, once per
    /// launch, buys an exit path with no way to hang.
    private func waitForBaseline() async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.startupTimeout)
        while ContinuousClock.now < deadline {
            let contents = state.contents
            if contents.hasBaseline { return }
            if let failure = contents.failure { throw StartError.sessionFailed(failure) }
            try? await Task.sleep(for: Self.startupPollInterval)
        }
        if let failure = state.contents.failure { throw StartError.sessionFailed(failure) }
        throw StartError.timedOut
    }

    /// Stops the session and waits for its thread to unwind.
    ///
    /// Waits rather than signals and returns: the thread owns a display
    /// connection and a handful of pipes, and a caller that started a second
    /// reader while the first was still tearing down would have two clients
    /// bound to one seat's selection.
    public func stop() async {
        guard let thread else { return }
        commands.append(.stop)
        wakeup?.signal()

        let deadline = ContinuousClock.now.advanced(by: Self.startupTimeout)
        while state.contents.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.startupPollInterval)
        }
        _ = thread
        self.thread = nil
        wakeup?.close()
        wakeup = nil
        notifications = nil
    }

    /// Puts a payload on the clipboard, keyed by MIME target, or clears it.
    ///
    /// Skrepka keeps serving it until another client takes the selection —
    /// which is what a Wayland data source is: not a write, but an offer that
    /// stays live. Returns as soon as the request is queued; the loop performs
    /// it on its next pass.
    public func setSelection(_ payload: [String: Data]?) {
        commands.append(.setSelection(payload))
        wakeup?.signal()
    }

    /// Why the session stopped, when it stopped for a reason.
    public var failure: String? { state.contents.failure }

    // MARK: - ClipboardSource

    public func changeCount() -> Int { state.contents.changeCount }

    /// - Parameter sourceBundleID: ignored. Design §8: there is no Linux
    ///   analogue of a bundle identifier, and filling it with a process name
    ///   would put something in the field that no surface reading it means.
    public func read(sourceBundleID: String?) -> PasteboardRead { state.contents.read }

    public func changeNotifications() -> AsyncStream<Void>? { notifications }
}
