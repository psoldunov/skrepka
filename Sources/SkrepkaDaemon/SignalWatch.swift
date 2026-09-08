import Foundation
import Synchronization

#if canImport(Glibc)
    import Glibc
#endif

/// Waits for `SIGINT` or `SIGTERM`.
///
/// ## Why a polled flag rather than a continuation
///
/// A signal handler runs on whatever thread the signal was delivered to, and
/// the set of things it may legally do is tiny: POSIX permits only
/// async-signal-safe functions inside one. Resuming a Swift continuation is not
/// among them — it touches the concurrency runtime's locks, which the
/// interrupted thread may already hold, and the failure mode is a deadlock at
/// shutdown that reproduces once a fortnight.
///
/// So the handler does the one thing it is allowed to do — store to an atomic —
/// and a task outside it polls that flag. A tenth of a second of shutdown
/// latency, once per process, for a shutdown path with no way to hang.
///
/// `sigaction` rather than `signal`: `signal`'s behaviour on re-arming differs
/// between systems and its handler may be reset after the first delivery, which
/// would make a second `SIGTERM` kill the process outright and skip the clean
/// stop this whole type exists to reach.
public enum SignalWatch {
    /// How often the waiter looks at the flag.
    static let pollInterval: Duration = .milliseconds(100)

    /// Set from inside the signal handler, read from a task.
    ///
    /// `Atomic` because a plain `Bool` written from a signal handler and read
    /// from a thread is a data race that the compiler cannot see and the
    /// hardware may not resolve the way the source reads.
    private static let terminating = Atomic<Bool>(false)

    /// Installs the handlers, and answers whether both took.
    ///
    /// Called before the start path rather than left to
    /// ``waitForTermination()``. A `SIGTERM` that arrives while the daemon is
    /// still opening the store or binding a listener — systemd's
    /// `TimeoutStartSec`, or a `systemctl stop` typed a second too early —
    /// otherwise meets the default disposition and kills the process outright,
    /// skipping the clean stop this type exists for.
    ///
    /// Idempotent: installing the same handler twice is harmless.
    @discardableResult
    public static func installHandlers() -> Bool {
        // Both, not `&&`: short-circuiting would leave SIGTERM uninstalled
        // because SIGINT failed.
        let interrupt = install(SIGINT)
        let terminate = install(SIGTERM)
        return interrupt && terminate
    }

    /// Installs the handlers if nobody has, and returns once one has fired.
    ///
    /// Idempotent in the sense that matters: installing the same handler twice
    /// is harmless, and a second caller waits on the same flag.
    public static func waitForTermination() async {
        installHandlers()
        while !terminating.load(ordering: .relaxed) {
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancelled. The caller has decided to stop for its own
                // reasons, which is exactly what this was waiting to hear.
                return
            }
        }
    }

    /// Whether a termination signal has arrived. For tests, and for a caller
    /// that wants to check without waiting.
    public static var isTerminating: Bool { terminating.load(ordering: .relaxed) }

    private static func install(_ signalNumber: Int32) -> Bool {
        // Not a no-op, and not safe to delete. `terminating` is a `static let`
        // with a non-trivial initialiser, so Swift creates it lazily through
        // `swift_once` on first access — which takes a lock and is not
        // async-signal-safe. Touching it here, before `sigaction` arms the
        // handler, guarantees the initialiser has already run by the time a
        // signal can arrive and make the handler's own store the first access.
        _ = terminating.load(ordering: .relaxed)

        var action = sigaction()
        // The handler stores to an atomic and returns. That is the whole of
        // what is safe to do here; see the type's discussion.
        action.__sigaction_handler = unsafeBitCast(
            handler as @convention(c) (Int32) -> Void,
            to: sigaction.__Unnamed_union___sigaction_handler.self
        )
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        // Reported rather than dropped. It can only fail on a signal number
        // this platform will not let a process catch, and a daemon that
        // silently has no `SIGTERM` handler is one systemd will `SIGKILL` at
        // the end of every stop.
        return sigaction(signalNumber, &action, nil) == 0
    }

    private static let handler: @convention(c) (Int32) -> Void = { _ in
        SignalWatch.terminating.store(true, ordering: .relaxed)
    }
}
