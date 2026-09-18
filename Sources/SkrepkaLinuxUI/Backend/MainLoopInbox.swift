import CGtk4
import Glibc
import Synchronization

/// Values posted from any thread, collected on GTK's main loop.
///
/// ## Why this exists
///
/// A window here talks to the daemon through `DaemonProxy`, which is `async`
/// and answers on Swift's concurrency pool. GTK must only be touched from the
/// thread running its main loop. Something has to carry an answer from the one
/// to the other, and the obvious candidates are each a claim this repository
/// bans: `MainActor.assumeIsolated` asserts a thread the compiler cannot see,
/// and a `@Sendable` closure that captures a window needs `@unchecked
/// Sendable` to compile at all.
///
/// So nothing that touches a widget crosses threads. What crosses is a
/// `Sendable` value, into a queue behind a `Mutex`, and a write to an eventfd.
/// The loop's end — ``MainLoopWatch`` — owns everything else: the widgets, the
/// closure that updates them, and the `g_unix_fd_source` that wakes when the
/// descriptor becomes readable. The compiler checks all of it; the only
/// pointer involved is GLib's user data, which never leaves the loop thread.
///
/// ## Ordering
///
/// ``post(_:)`` appends and *then* signals; ``take()`` clears the descriptor
/// and *then* empties the queue. A post that lands between the two is either
/// already in the queue this take empties, or signals again after the clear
/// and wakes the loop once more — never lost. The price is an occasional wake
/// that finds nothing, which costs one lock.
public final class MainLoopInbox<Message: Sendable>: Sendable {
    /// Why an inbox could not be made.
    public enum Unavailable: Error, CustomStringConvertible {
        case noDescriptor(errno: Int32)

        public var description: String {
            switch self {
            case .noDescriptor(let code):
                "could not create an eventfd to wake the main loop (errno \(code))"
            }
        }
    }

    private let pending = Mutex<[Message]>([])

    /// The eventfd a ``MainLoopWatch`` polls. Owned here and closed in
    /// `deinit`, which the watch cannot outlive: it holds this inbox.
    let descriptor: Int32

    public init() throws {
        let descriptor = skrepka_wake_fd_new()
        guard descriptor >= 0 else { throw Unavailable.noDescriptor(errno: errno) }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Queues `message` for the loop. Safe from any thread, including the
    /// loop's own; delivery is always later, never re-entrant.
    public func post(_ message: Message) {
        pending.withLock { $0.append(message) }
        skrepka_wake_fd_signal(descriptor)
    }

    /// Everything posted so far, oldest first, and an empty queue behind it.
    func take() -> [Message] {
        skrepka_wake_fd_clear(descriptor)
        return pending.withLock { queue in
            let taken = queue
            queue.removeAll()
            return taken
        }
    }
}
