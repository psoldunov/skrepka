import Foundation

@testable import SkrepkaCore

/// A ``ClipboardSource`` a test can drive by hand.
///
/// An actor rather than a struct with a lock, so it conforms the same way the
/// real Linux backends will: they hold a live compositor connection, so they
/// are actors too, and a test double that conforms more easily than production
/// code does is a double that hides conformance problems.
///
/// Push or poll is chosen at construction. With `pushes: true` the source
/// reports a notification stream and ``notifyChange()`` drives the watcher
/// exactly the way `XFixesSelectionNotify` will; with `pushes: false` it
/// returns nil and ``ClipboardWatcher`` falls back to its timer, which is what
/// `NSPasteboard` gets.
actor FakeClipboardSource: ClipboardSource {
    private var count = 0
    private var contents: PasteboardRead = .unreadable
    private var notifications: AsyncStream<Void>?
    private var notifier: AsyncStream<Void>.Continuation?

    /// Bundle identifier handed to the most recent read, so a test can check
    /// the watcher asked its source provider before reading.
    private(set) var lastSourceBundleID: String?
    /// How many times the clipboard was actually read. A change that is
    /// de-duplicated or paused must not touch this.
    private(set) var readCount = 0

    init(pushes: Bool = false) {
        guard pushes else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        notifications = stream
        notifier = continuation
    }

    // MARK: - ClipboardSource

    func changeCount() -> Int { count }

    /// Stamps the caller's bundle identifier onto the snapshot, the way
    /// ``PasteboardReader`` does — a source that dropped it would let a test
    /// pass while the watcher never asked its source provider anything.
    func read(sourceBundleID: String?) -> PasteboardRead {
        readCount += 1
        lastSourceBundleID = sourceBundleID
        guard case .contents(let snapshot) = contents else { return contents }
        return .contents(
            PasteboardSnapshot(
                representations: snapshot.representations,
                declaredTypes: snapshot.declaredTypes,
                sourceBundleID: sourceBundleID,
                capturedAt: snapshot.capturedAt
            )
        )
    }

    func changeNotifications() -> AsyncStream<Void>? { notifications }

    // MARK: - Driving the fake

    /// Puts something new on the clipboard: bumps the identity and swaps the
    /// contents, the way a real copy does both at once.
    func put(_ read: PasteboardRead) {
        count += 1
        contents = read
    }

    /// The source app is not a parameter here: ``read(sourceBundleID:)``
    /// stamps whatever the watcher asks for, which is where it comes from in
    /// production too.
    func put(text: String) {
        put(
            .contents(
                PasteboardSnapshot(
                    representations: [PasteboardType.string: Data(text.utf8)],
                    declaredTypes: [PasteboardType.string]
                )
            )
        )
    }

    /// Declares a type Skrepka reads and hands back no bytes for it — what a
    /// denied pasteboard looks like from inside the app.
    func putUnreadable() {
        put(.unreadable)
    }

    /// Fires one change notification, for a source built with `pushes: true`.
    func notifyChange() {
        notifier?.yield()
    }

}
