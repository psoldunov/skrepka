import Foundation
import SkrepkaCore

extension XClipboardSession.Command: LinuxSessionCommand {}

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
///
/// The thread, the wakeup pipe and the baseline wait are
/// ``LinuxSessionRunner``'s, shared with ``DataControlReader``.
public actor XFixesReader: ClipboardSource {
    public typealias StartError = LinuxSessionStartError

    private let displayName: String?
    private let runner = LinuxSessionRunner<XClipboardSession.Command>()

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
        let displayName = self.displayName
        try await runner.start(threadNamed: "dev.soldunov.skrepka.x11-clipboard") { context in
            XClipboardSession(
                state: context.state, notify: context.notify, displayName: displayName
            )
            .run(commands: context.commands, wakeup: context.wakeup)
        }
    }

    /// Stops the session and waits for its thread to unwind, so the X
    /// connection and the selection ownership are both gone before this
    /// returns.
    public func stop() async {
        await runner.stop()
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
        runner.setSelection(payload)
    }

    public var failure: String? { runner.failure }

    // MARK: - ClipboardSource

    public func changeCount() -> Int { runner.state.contents.changeCount }

    /// - Parameter sourceBundleID: ignored, for the reason design §8 gives:
    ///   there is no Linux analogue.
    public func read(sourceBundleID: String?) -> PasteboardRead { runner.state.contents.read }

    public func changeNotifications() -> AsyncStream<Void>? { runner.notifications }
}
