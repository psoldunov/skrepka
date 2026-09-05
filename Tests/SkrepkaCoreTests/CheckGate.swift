// A test double, in a file of its own beside `FakeClipboardSource` for the same
// reason: it is scaffolding rather than a suite, and `ClipboardWatcherTests` is
// already at the length the repository asks files to stay under.

/// Holds a ``ClipboardWatcher/checkForChange()`` open at its `sourceProvider`
/// call, so a test can act while the watcher's actor is released.
///
/// An actor rather than a lock and a semaphore: it is driven from inside a
/// `@Sendable async` closure and from the test at the same time, which is the
/// shape of the race it exists to reproduce.
///
/// Every entrant is tracked rather than only the first. ``ClipboardWatcher/start()``
/// launches a polling loop that takes its own look, and whether that look reaches
/// the gate before the test's does is a scheduling detail no assertion here should
/// depend on — so ``open()`` releases all of them and ``enter()`` returns straight
/// away for anything arriving afterwards.
actor CheckGate {
    private var entered = 0
    private var firstEntry: CheckedContinuation<Void, Never>?
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    /// Called from inside the watcher's `sourceProvider`. Returns once ``open()``
    /// has been called, immediately if it already has.
    func enter() async {
        entered += 1
        firstEntry?.resume()
        firstEntry = nil
        guard !isOpen else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting.append(continuation)
        }
    }

    /// Returns once a check is suspended inside ``enter()``.
    func waitForFirstEntry() async {
        guard entered == 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            firstEntry = continuation
        }
    }

    func open() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}
