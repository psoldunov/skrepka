import Foundation
import SkrepkaCore

/// A ``SkrepkaCore/ClipboardSource`` over Xlib and the XFIXES extension.
///
/// The one backend that is strictly better than the macOS one.
/// `XFixesSelectSelectionInput` registers for `XFixesSelectionNotify` and the
/// selection change arrives as a real event, so ``changeNotifications()``
/// returns a stream and `ClipboardWatcher` runs no timer at all. macOS is stuck
/// at a 200 ms tick because `NSPasteboard.h` in the macOS 26 SDK declares no
/// change notification of any kind.
///
/// Works over a real X server and over XWayland. Under XWayland it is the lossy
/// path — it sees only what XWayland clients put on the clipboard, and a native
/// Wayland application's copy is invisible to it — which is what
/// ``SessionProbe/Report/isXWaylandFallback`` exists to report.
public actor XFixesReader: ClipboardSource {
    public enum StartError: Error, Equatable {
        case outOfFileDescriptors
        case sessionFailed(String)
        case timedOut
    }

    private let displayName: String?
    private let state = LinuxClipboardState()
    private let commands = CommandQueue<XClipboardSession.Command>()
    private var wakeup: WakePipe?
    private var thread: Thread?
    private var notifications: AsyncStream<Void>?

    /// - Parameter displayName: which X server to connect to, or nil to let
    ///   Xlib read `DISPLAY`.
    public init(displayName: String? = nil) {
        self.displayName = displayName
    }

    /// Connects, and returns once the clipboard's current contents have been
    /// read.
    ///
    /// The wait is not politeness. XFIXES reports changes from the moment it is
    /// selected, so whatever was already on the clipboard arrives only because
    /// the session asks for it explicitly at connect — and `ClipboardWatcher`
    /// baselines on the first change count it reads, so starting it before that
    /// answer lands turns the user's existing clipboard into a fresh capture.
    public func start() async throws {
        guard thread == nil else { return }
        guard let wakeup = WakePipe() else { throw StartError.outOfFileDescriptors }
        self.wakeup = wakeup

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        notifications = stream

        let state = self.state
        let commands = self.commands
        let displayName = self.displayName
        let thread = Thread {
            XClipboardSession(state: state, notify: continuation, displayName: displayName)
                .run(commands: commands, wakeup: wakeup)
        }
        thread.name = "dev.soldunov.skrepka.x11-clipboard"
        self.thread = thread
        thread.start()

        try await waitForBaseline()
    }

    private func waitForBaseline() async throws {
        let deadline = ContinuousClock.now.advanced(by: DataControlReader.startupTimeout)
        while ContinuousClock.now < deadline {
            let contents = state.contents
            if contents.hasBaseline { return }
            if let failure = contents.failure { throw StartError.sessionFailed(failure) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let failure = state.contents.failure { throw StartError.sessionFailed(failure) }
        throw StartError.timedOut
    }

    /// Stops the session and waits for its thread to unwind, so the X
    /// connection and the selection ownership are both gone before this
    /// returns.
    public func stop() async {
        guard thread != nil else { return }
        commands.append(.stop)
        wakeup?.signal()

        let deadline = ContinuousClock.now.advanced(by: DataControlReader.startupTimeout)
        while state.contents.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        thread = nil
        wakeup?.close()
        wakeup = nil
        notifications = nil
    }

    /// Takes ownership of `CLIPBOARD` and serves these bytes, keyed by target
    /// name, or gives ownership up.
    ///
    /// Ownership rather than a write: X11 has no clipboard buffer, only an
    /// owner that answers requests. Skrepka keeps answering until another
    /// client takes the selection — which also means the contents vanish if
    /// Skrepka exits, unless a clipboard manager saved them, and Skrepka is not
    /// yet acting as one on Linux.
    public func setSelection(_ payload: [String: Data]?) {
        commands.append(.setSelection(payload))
        wakeup?.signal()
    }

    public var failure: String? { state.contents.failure }

    // MARK: - ClipboardSource

    public func changeCount() -> Int { state.contents.changeCount }

    /// - Parameter sourceBundleID: ignored, for the reason design §8 gives:
    ///   there is no Linux analogue.
    public func read(sourceBundleID: String?) -> PasteboardRead { state.contents.read }

    public func changeNotifications() -> AsyncStream<Void>? { notifications }
}
