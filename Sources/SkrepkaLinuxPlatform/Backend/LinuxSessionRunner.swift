import Foundation
import SkrepkaCore
import Synchronization

/// How a backend's own thread is asked to do something.
///
/// Both session command enums already have exactly these two cases, so both
/// conform with an empty extension — an enum case satisfies a static protocol
/// requirement of the same shape.
protocol LinuxSessionCommand: Sendable {
    static var stop: Self { get }
    static func setSelection(_ payload: [String: Data]?) -> Self
}

/// How long a reader waits for its session, in one place.
///
/// Previously spelled twice: `DataControlReader` owned both constants and
/// `XFixesReader` reached across for the timeout and re-typed the interval as a
/// literal, so the two backends could drift apart without anything noticing.
enum LinuxSessionTiming {
    /// How long ``LinuxSessionRunner/start(threadNamed:body:)`` waits for the
    /// session to connect and read the clipboard's current contents.
    ///
    /// Generous, because it covers a compositor or server round trip plus a
    /// first capture that may be a large image, and because the alternative to
    /// waiting is worse: `ClipboardWatcher` baselines on the first change count
    /// it reads, so starting it before the session has one turns whatever was
    /// already on the clipboard into a fresh capture.
    static let startupTimeout: Duration = .seconds(3)

    /// How often the actor looks at the state the loop thread writes.
    ///
    /// A poll rather than a continuation resumed from the loop thread: the
    /// state is already behind a `Mutex` that the loop writes under, and adding
    /// a continuation to it would mean a second thing to get right on the exit
    /// path — a session that fails between the check and the wait would leave
    /// the caller suspended forever. Ten milliseconds of latency, once per
    /// launch, buys an exit path with no way to hang.
    static let pollInterval: Duration = .milliseconds(10)
}

/// Why a session did not start.
public enum LinuxSessionStartError: Error, Equatable {
    /// The process could not allocate the wakeup pipe.
    case outOfFileDescriptors
    /// The session ran and stopped, with the reason it gave.
    case sessionFailed(String)
    /// Nothing had gone wrong within ``LinuxSessionTiming/startupTimeout``, and
    /// nothing had finished either.
    case timedOut
}

/// The lifecycle both Linux clipboard readers run.
///
/// ``DataControlReader`` and ``XFixesReader`` were the same class typed out
/// twice: strip the doc comments and they differed in a thread name, the
/// session they constructed, and — on the Wayland side — the protocol binding.
/// Everything else was duplicated, which is the argument
/// ``DataControlReader`` already makes for driving both data-control protocols
/// from one engine, applied one level up. Actors cannot inherit, so the shared
/// part is a type the actor holds rather than a base class.
///
/// `Sendable` by the same means `LinuxClipboardState` and `CommandQueue` use: a
/// `Mutex` over a small value, so the actor holding this needs no isolation
/// ceremony to call it. Nothing here stores the `Thread` itself — it was only
/// ever read as a flag, and a `Bool` is both honest about that and the reason
/// this type can be `Sendable` at all.
final class LinuxSessionRunner<Command: LinuxSessionCommand>: Sendable {
    /// Everything the loop thread needs, handed over as one value so the thread
    /// body captures nothing belonging to the actor.
    struct SessionContext: Sendable {
        let state: LinuxClipboardState
        let commands: CommandQueue<Command>
        let wakeup: WakePipe
        let notify: AsyncStream<Void>.Continuation
    }

    private struct Storage: Sendable {
        var wakeup: WakePipe?
        var notifications: AsyncStream<Void>?
        var isThreadLive = false
    }

    let state = LinuxClipboardState()
    let commands = CommandQueue<Command>()
    private let storage = Mutex(Storage())

    var isRunning: Bool { storage.withLock { $0.isThreadLive } }
    var notifications: AsyncStream<Void>? { storage.withLock { $0.notifications } }
    var failure: String? { state.contents.failure }

    /// Starts the session on its own thread and returns once it has read the
    /// clipboard once.
    ///
    /// Explicit rather than lazy because `ClipboardSource` has no lifecycle and
    /// the session owns a thread: something has to say when it starts and when
    /// it stops, and hiding that inside the first `changeCount()` would make
    /// every caller pay a three-second timeout for a mistake in configuration.
    ///
    /// - Parameter body: builds the session and runs its loop. Called on the
    ///   new thread, and given everything it needs, so it captures nothing the
    ///   actor owns — which is what lets a non-`Sendable` session hold a
    ///   `wl_display` or an Xlib `Display` without an unchecked conformance.
    func start(
        threadNamed name: String,
        body: @escaping @Sendable (SessionContext) -> Void
    ) async throws {
        guard !isRunning else { return }
        guard let wakeup = WakePipe() else { throw LinuxSessionStartError.outOfFileDescriptors }

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        guard claimThread(wakeup: wakeup, notifications: stream) else {
            // Lost the race to another `start()`. The pipe this one allocated
            // is unreachable from here on, so it is closed rather than leaked.
            wakeup.close()
            return
        }

        let context = SessionContext(
            state: state, commands: commands, wakeup: wakeup, notify: continuation
        )
        let thread = Thread { body(context) }
        thread.name = name
        thread.start()

        try await waitForBaseline()
    }

    /// Stops the session and waits for its thread to unwind.
    ///
    /// Waits rather than signals and returns: the thread owns a display
    /// connection and a handful of pipes, and a caller that started a second
    /// reader while the first was still tearing down would have two clients
    /// bound to one seat's selection.
    func stop() async {
        guard let wakeup = storage.withLock({ $0.isThreadLive ? $0.wakeup : nil }) else { return }
        commands.append(.stop)
        wakeup.signal()
        await waitUntilStopped()
        storage.withLock {
            $0.wakeup?.close()
            $0.wakeup = nil
            $0.notifications = nil
            $0.isThreadLive = false
        }
    }

    /// Queues a selection change and wakes the loop to perform it.
    func setSelection(_ payload: [String: Data]?) {
        commands.append(.setSelection(payload))
        storage.withLock { $0.wakeup }?.signal()
    }

    /// Takes the single thread slot, or reports that it was already taken.
    ///
    /// One `withLock` rather than a check and a later write, so two `start()`
    /// calls cannot both believe they are the first.
    private func claimThread(wakeup: WakePipe, notifications: AsyncStream<Void>) -> Bool {
        storage.withLock {
            guard !$0.isThreadLive else { return false }
            $0.isThreadLive = true
            $0.wakeup = wakeup
            $0.notifications = notifications
            return true
        }
    }

    /// Polls the shared state until the session has read the clipboard once.
    ///
    /// `try await` rather than `try?`: a cancelled `Task.sleep` throws
    /// immediately, so discarding the error would turn this deadline loop into
    /// a busy spin for the remainder of the timeout — at exactly the moment the
    /// caller has said it no longer wants the answer. Cancellation propagates
    /// out of `start()` instead.
    private func waitForBaseline() async throws {
        let deadline = ContinuousClock.now.advanced(by: LinuxSessionTiming.startupTimeout)
        while ContinuousClock.now < deadline {
            let contents = state.contents
            if contents.hasBaseline { return }
            if let failure = contents.failure { throw LinuxSessionStartError.sessionFailed(failure) }
            try await Task.sleep(for: LinuxSessionTiming.pollInterval)
        }
        if let failure = state.contents.failure {
            throw LinuxSessionStartError.sessionFailed(failure)
        }
        throw LinuxSessionStartError.timedOut
    }

    /// Waits for the loop to report that it has unwound, or gives up.
    ///
    /// Cancellation stops the waiting but not the teardown: whoever cancelled
    /// still needs the pipe closed and the stream released, so the sleep failing
    /// breaks the loop rather than propagating. Giving up on the deadline is the
    /// same path — a loop wedged in `poll` is not made better by blocking its
    /// caller forever.
    private func waitUntilStopped() async {
        let deadline = ContinuousClock.now.advanced(by: LinuxSessionTiming.startupTimeout)
        while state.contents.isRunning, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: LinuxSessionTiming.pollInterval)
            } catch {
                break
            }
        }
    }
}
