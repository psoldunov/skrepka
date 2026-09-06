import Foundation

/// Watches a ``ClipboardSource`` and emits every capture that survives the
/// privacy rules.
///
/// Two modes, and the source picks which one. A source that can push says so
/// with ``ClipboardSource/changeNotifications()``, and then no timer runs at
/// all — X11's `XFixesSelectionNotify` and Wayland's data-control protocols
/// both arrive that way. A source that cannot push has to be polled, which is
/// macOS: `NSPasteboard.h` in the macOS 26 SDK declares no change notification
/// of any kind. Reading `changeCount` is a single IPC round-trip, so a 200 ms
/// cadence costs almost nothing and is imperceptible in a copy-then-hotkey
/// flow.
///
/// An `actor` rather than a main-actor type on purpose: per SE-0466
/// declarations inside an actor are exempt from the app target's default
/// isolation, so this stays off the main actor without annotation.
public actor ClipboardWatcher {
    public typealias SourceProvider = @Sendable () async -> String?

    private let source: any ClipboardSource
    private let pollInterval: Duration
    private let sourceProvider: SourceProvider

    /// Identity of the last selection this watcher has already dealt with, or
    /// nil before the first look. Nil is what makes the first check establish a
    /// baseline instead of emitting whatever happened to be on the clipboard
    /// when Skrepka launched.
    private var lastChangeCount: Int?
    /// Whichever of the two loops ``start()`` chose. One property, because only
    /// one of them ever runs.
    private var watchTask: Task<Void, Never>?
    private var continuation: AsyncStream<CaptureDecision>.Continuation?
    private var rules: CaptureRules
    private var isPaused = false

    /// - Parameters:
    ///   - source: Where clippings come from. No default: the previous one
    ///     built an `NSPasteboard` reader in the argument list, which reached
    ///     for the live system clipboard from inside a test.
    ///   - pollInterval: How often to look. Applies only when `source` has to
    ///     be polled — a source that delivers notifications is never on a
    ///     timer, and this is ignored entirely.
    public init(
        source: any ClipboardSource,
        rules: CaptureRules = CaptureRules(),
        pollInterval: Duration = .milliseconds(200),
        sourceProvider: @escaping SourceProvider = { nil }
    ) {
        self.source = source
        self.rules = rules
        self.pollInterval = pollInterval
        self.sourceProvider = sourceProvider
    }

    /// Starts watching and returns the stream of decisions. Calling it again
    /// replaces the previous stream.
    ///
    /// Baselines the change counter before the first look, so the clipboard's
    /// existing contents are not recaptured — and so an event-driven source
    /// does not spend its first real notification establishing that baseline.
    public func start() async -> AsyncStream<CaptureDecision> {
        stop()
        lastChangeCount = await source.changeCount()
        let (stream, continuation) = AsyncStream<CaptureDecision>.makeStream()
        self.continuation = continuation
        watchTask =
            if let notifications = await source.changeNotifications() {
                notificationLoop(notifications)
            } else {
                pollingLoop()
            }
        return stream
    }

    /// Push mode: one look per notification, and nothing on a timer.
    private func notificationLoop(_ notifications: AsyncStream<Void>) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in notifications {
                guard !Task.isCancelled else { return }
                await self?.checkForChange()
            }
        }
    }

    /// Poll mode, for a source that cannot say when it changed.
    private func pollingLoop() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForChange()
                // The only thing this throws is cancellation, which the loop
                // condition handles on the next pass.
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(200))
            }
        }
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Suspends capture while Skrepka itself owns the clipboard, so pasting an
    /// entry does not re-record it.
    ///
    /// Takes effect on a look that is already in flight as well as on the next
    /// one — see ``checkForChange()``. It has to: the paste is written between
    /// this call and ``resume()``, so a check suspended across that window is
    /// precisely the one that would read the paste back.
    public func pause() {
        isPaused = true
    }

    /// Resumes capture, ignoring whatever happened while paused.
    public func resume() async {
        lastChangeCount = await source.changeCount()
        isPaused = false
    }

    public func updateRules(_ rules: CaptureRules) {
        self.rules = rules
    }

    /// One look at the clipboard — a notification's worth in push mode, a timer
    /// beat's worth when polling. Internal rather than private so a test can
    /// drive either loop a step at a time instead of racing a timer.
    ///
    /// **Every `await` below releases the actor, and ``pause()`` and
    /// ``resume()`` are exactly what runs in the gap** — the paste path calls
    /// one on each side of a write of its own to the clipboard. So the pause
    /// state is re-read after each suspension rather than once at the top.
    /// Reading it once let a check that began before the paste finish after it
    /// and read back Skrepka's own paste-back as a fresh capture: ordinarily a
    /// duplicate that reorders history, and at worst a concealed clip pasted as
    /// plain text landing as a new *unconcealed* row, which ``syncIndex`` would
    /// then offer to peers.
    func checkForChange() async {
        let current = await source.changeCount()
        guard let last = lastChangeCount else {
            lastChangeCount = current
            return
        }
        guard current != last, !isPaused else { return }
        // Written before the read rather than after, so two checks that overlap
        // cannot both act on one change. It doubles as this call's token: only
        // a ``resume()`` re-baselining onto something newer can change it back.
        lastChangeCount = current

        let bundleID = await sourceProvider()
        guard isStillCurrent(current) else { return }
        let read = await source.read(sourceBundleID: bundleID)
        guard isStillCurrent(current) else { return }

        switch read {
        case .contents(let snapshot):
            continuation?.yield(rules.decide(snapshot))
        case .unreadable:
            // Emitted rather than dropped. This is what a denied pasteboard
            // looks like, and swallowing it here is what made an unusable
            // install indistinguishable from an idle one.
            continuation?.yield(.rejectedUnreadable)
        }
    }

    /// Whether the change this check picked up is still the one to act on.
    ///
    /// False once a pause has begun, and false when a ``resume()`` has
    /// re-baselined the counter past it — which is what a pause-and-resume
    /// straddling this check looks like from here. Dropping the look is the
    /// conservative half of that: the clipboard now holds something this check
    /// never read, and ``resume()`` promises whatever happened in between is
    /// discarded.
    private func isStillCurrent(_ changeCount: Int) -> Bool {
        !isPaused && lastChangeCount == changeCount
    }
}
