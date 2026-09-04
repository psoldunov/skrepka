import Foundation

/// Watches the general pasteboard and emits every capture that survives the
/// privacy rules.
///
/// Polling is the only option: `NSPasteboard.h` in the macOS 26 SDK declares no
/// change notification of any kind. Reading `changeCount` is a single IPC
/// round-trip, so a 200 ms cadence costs almost nothing and is imperceptible in
/// a copy-then-hotkey flow.
///
/// An `actor` rather than a main-actor type on purpose: per SE-0466 declarations
/// inside an actor are exempt from the app target's default isolation, so this
/// stays off the main actor without annotation.
public actor PasteboardPoller {
    public typealias SourceProvider = @Sendable () async -> String?

    private let reader: PasteboardReader
    private let interval: Duration
    private let sourceProvider: SourceProvider

    private var lastChangeCount: Int
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<CaptureDecision>.Continuation?
    private var rules: CaptureRules
    private var isPaused = false

    public init(
        reader: PasteboardReader = PasteboardReader(),
        rules: CaptureRules = CaptureRules(),
        interval: Duration = .milliseconds(200),
        sourceProvider: @escaping SourceProvider = { nil }
    ) {
        self.reader = reader
        self.rules = rules
        self.interval = interval
        self.sourceProvider = sourceProvider
        self.lastChangeCount = reader.changeCount()
    }

    /// Starts polling and returns the stream of decisions. Calling it again
    /// replaces the previous stream.
    public func start() -> AsyncStream<CaptureDecision> {
        stop()
        let (stream, continuation) = AsyncStream<CaptureDecision>.makeStream()
        self.continuation = continuation
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: self?.interval ?? .milliseconds(200))
            }
        }
        return stream
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Suspends capture while Clippy itself owns the pasteboard, so pasting an
    /// entry does not re-record it.
    public func pause() {
        isPaused = true
    }

    /// Resumes capture, ignoring whatever happened while paused.
    public func resume() {
        lastChangeCount = reader.changeCount()
        isPaused = false
    }

    public func updateRules(_ rules: CaptureRules) {
        self.rules = rules
    }

    private func tick() async {
        let current = reader.changeCount()
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        guard !isPaused else { return }

        let source = await sourceProvider()
        switch reader.read(sourceBundleID: source) {
        case .contents(let snapshot):
            continuation?.yield(rules.decide(snapshot))
        case .unreadable:
            // Emitted rather than dropped. This is what a denied pasteboard
            // looks like, and swallowing it here is what made an unusable
            // install indistinguishable from an idle one.
            continuation?.yield(.rejectedUnreadable)
        }
    }
}
