import Foundation
import SkrepkaCore
import Synchronization

/// The handoff between a backend's own thread and the actor that publishes it.
///
/// Every Linux backend here owns a thread that is not the Swift concurrency
/// runtime's — libwayland and Xlib both want a connection driven by one thread
/// running a `poll` loop, and neither can be awaited. This is the only thing
/// that crosses between that thread and the actor: a counter, the last read,
/// and whether the loop is still alive.
///
/// A `Mutex` rather than an actor because the writing side is a C event
/// callback with no way to `await`, and rather than an atomic because the
/// counter and the read have to move together — a reader that saw a new counter
/// beside the previous read would hand `ClipboardWatcher` stale bytes under a
/// fresh identity, which is a clipping silently replaced by the one before it.
///
/// Notifications travel separately, through an `AsyncStream.Continuation`,
/// which is safe to yield to from any thread by its own documentation.
final class LinuxClipboardState: Sendable {
    /// Everything the actor can learn about the session, as one value.
    struct Contents: Sendable {
        /// Identity of the current selection. Bumped once per selection change,
        /// never derived from anything the compositor sends, because neither
        /// Wayland nor X11 offers a counter of its own.
        var changeCount = 0
        var read: PasteboardRead = .contents(
            PasteboardSnapshot(representations: [:], declaredTypes: [])
        )
        /// False before the loop has connected, and again once it has stopped.
        var isRunning = false
        /// Whether the loop has seen its first selection.
        ///
        /// Both data-control protocols send a `selection` event on binding the
        /// device, and an X11 session has a selection owner from the moment
        /// Skrepka starts, so "what is on the clipboard right now" always
        /// arrives as an event rather than being there to read. Until it has,
        /// `changeCount` is a number about nothing — and `ClipboardWatcher`
        /// baselines on the first count it reads, so starting it early is what
        /// would make the clipboard's existing contents look like a fresh copy.
        var hasBaseline = false
        /// Why the loop stopped, when it stopped for a reason.
        var failure: String?
    }

    private let storage = Mutex(Contents())

    var contents: Contents { storage.withLock { $0 } }

    /// The closure is applied inside a literal rather than forwarded straight
    /// to `withLock`: that parameter is `(inout sending Contents) -> sending
    /// Void`, and handing it a plain function value is refused as a way for an
    /// isolated value to escape through the result.
    func update(_ body: (inout Contents) -> Void) {
        storage.withLock { body(&$0) }
    }

    /// Records a new selection: the read and the counter move together, under
    /// one lock, and the baseline is established by the first one.
    func publish(_ read: PasteboardRead) {
        storage.withLock {
            $0.read = read
            $0.changeCount &+= 1
            $0.hasBaseline = true
        }
    }
}
