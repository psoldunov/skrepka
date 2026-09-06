import Foundation
import Testing

@testable import SkrepkaCore

/// The capture loop, tested for the first time.
///
/// It could not be before: the watcher built a ``PasteboardReader`` in its own
/// default argument, so constructing one in a test reached for the machine's
/// real clipboard. That is the macOS-side reason ``ClipboardSource`` exists,
/// independent of Linux.
///
/// The loop is driven by hand — a long poll interval and an explicit
/// ``ClipboardWatcher/checkForChange()`` — rather than by waiting on the timer,
/// so nothing here is timing-dependent.
@Suite("Clipboard watcher")
struct ClipboardWatcherTests {
    /// A poll interval no test waits for. The polling loop looks once at start
    /// and then sleeps past the end of the run.
    private static let neverAgain: Duration = .seconds(3600)

    private func makeWatcher(
        source: FakeClipboardSource,
        rules: CaptureRules = CaptureRules(),
        sourceBundleID: String? = nil
    ) -> ClipboardWatcher {
        ClipboardWatcher(
            source: source,
            rules: rules,
            pollInterval: Self.neverAgain,
            sourceProvider: { sourceBundleID }
        )
    }

    /// The next decision, or nil if the stream ended first.
    private func next(
        _ stream: AsyncStream<CaptureDecision>
    ) async -> CaptureDecision? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    @Test("A change on the clipboard becomes a decision")
    func changeProducesDecision() async throws {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source, sourceBundleID: "com.example.editor")
        let stream = await watcher.start()

        await source.put(text: "hello")
        await watcher.checkForChange()

        let decision = await next(stream)
        let item = try #require(decision?.item)
        #expect(item.text == "hello")
        #expect(item.sourceBundleID == "com.example.editor")
        #expect(await source.lastSourceBundleID == "com.example.editor")
    }

    @Test("The clipboard's existing contents are not recaptured on start")
    func startDoesNotCaptureWhatWasAlreadyThere() async {
        let source = FakeClipboardSource()
        await source.put(text: "copied before Skrepka launched")

        let watcher = makeWatcher(source: source)
        _ = await watcher.start()
        await watcher.checkForChange()

        #expect(await source.readCount == 0)
    }

    @Test("An unchanged counter is not read again")
    func unchangedCounterIsNotRead() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source)
        _ = await watcher.start()

        await source.put(text: "once")
        await watcher.checkForChange()
        await watcher.checkForChange()
        await watcher.checkForChange()

        #expect(await source.readCount == 1)
    }

    @Test("Nothing is captured while paused")
    func pauseSuppressesCapture() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source)
        _ = await watcher.start()

        await watcher.pause()
        await source.put(text: "pasted back by Skrepka itself")
        await watcher.checkForChange()

        #expect(await source.readCount == 0)
    }

    @Test("Resuming discards what happened while paused")
    func resumeDiscardsWhatHappenedWhilePaused() async throws {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source)
        let stream = await watcher.start()

        await watcher.pause()
        await source.put(text: "pasted back by Skrepka itself")
        await watcher.checkForChange()
        await watcher.resume()

        // The paused change is gone for good — a look straight after resume
        // sees nothing new, because resume re-baselined onto it.
        await watcher.checkForChange()
        #expect(await source.readCount == 0)

        // The next genuine copy still lands.
        await source.put(text: "typed by the user")
        await watcher.checkForChange()
        let item = try #require(await next(stream)?.item)
        #expect(item.text == "typed by the user")
    }

    /// The race `AppCoordinator` opens on every paste: `pause()` and `resume()`
    /// run either side of a write to the clipboard, and a check that has already
    /// passed its guards is suspended in `sourceProvider` — off the actor, so
    /// both of them get to run. Before the counter and the pause state were
    /// re-read after each suspension, the resumed check read the *pasted* clip
    /// and yielded it as a capture: a duplicate that reorders history, or, for a
    /// concealed clip pasted as plain text, a new unconcealed row carrying the
    /// secret into `syncIndex`.
    ///
    /// Driven by a gate rather than by sleeping, so this asserts the ordering
    /// rather than outrunning it.
    @Test("A paste that lands mid-check is not captured")
    func pauseDuringACheckSuppressesTheCapture() async {
        let source = FakeClipboardSource()
        let gate = CheckGate()
        let watcher = ClipboardWatcher(
            source: source,
            pollInterval: Self.neverAgain,
            sourceProvider: {
                await gate.enter()
                return nil
            }
        )
        _ = await watcher.start()

        await source.put(text: "copied by the user")
        let check = Task { await watcher.checkForChange() }
        await gate.waitForFirstEntry()

        // Exactly what pasting does, while the check above is suspended.
        await watcher.pause()
        await source.put(text: "pasted back by Skrepka itself")
        await watcher.resume()

        await gate.open()
        await check.value

        #expect(await source.readCount == 0)
    }

    /// The other half of the guard: a check that spans no pause still captures.
    /// Re-reading the state after a suspension must not turn every slow
    /// `sourceProvider` into a dropped copy.
    @Test("A check suspended across no pause still captures")
    func aSuspendedCheckStillCaptures() async throws {
        let source = FakeClipboardSource()
        let gate = CheckGate()
        let watcher = ClipboardWatcher(
            source: source,
            pollInterval: Self.neverAgain,
            sourceProvider: {
                await gate.enter()
                return "com.example.editor"
            }
        )
        let stream = await watcher.start()

        await source.put(text: "copied by the user")
        let check = Task { await watcher.checkForChange() }
        await gate.waitForFirstEntry()
        await gate.open()
        await check.value

        let item = try #require(await next(stream)?.item)
        #expect(item.text == "copied by the user")
    }

    @Test("An unreadable clipboard is reported, not dropped")
    func unreadableIsEmitted() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source)
        let stream = await watcher.start()

        await source.putUnreadable()
        await watcher.checkForChange()

        #expect(await next(stream) == .rejectedUnreadable)
    }

    @Test("Rules are applied to what the source hands back")
    func rulesReject() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(
            source: source,
            rules: CaptureRules(excludedBundleIDs: ["com.example.vault"]),
            sourceBundleID: "com.example.vault"
        )
        let stream = await watcher.start()

        await source.put(text: "a secret")
        await watcher.checkForChange()

        #expect(await next(stream) == .rejectedExcludedApp(bundleID: "com.example.vault"))
    }

    @Test("Updated rules take effect on the next change")
    func updatedRulesTakeEffect() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source, sourceBundleID: "com.example.vault")
        let stream = await watcher.start()

        await watcher.updateRules(CaptureRules(excludedBundleIDs: ["com.example.vault"]))
        await source.put(text: "a secret")
        await watcher.checkForChange()

        #expect(await next(stream) == .rejectedExcludedApp(bundleID: "com.example.vault"))
    }

    @Test("Stopping ends the stream")
    func stopFinishesTheStream() async {
        let source = FakeClipboardSource()
        let watcher = makeWatcher(source: source)
        let stream = await watcher.start()

        await watcher.stop()

        #expect(await next(stream) == nil)
    }

    /// The event-driven path, which is the one Phase 5's X11 and Wayland
    /// backends take. No timer runs at all here: the only thing that moves the
    /// loop is a notification, exactly as `XFixesSelectionNotify` will.
    @Test("A push source drives capture without a timer")
    func pushSourceDrivesCapture() async throws {
        let source = FakeClipboardSource(pushes: true)
        let watcher = ClipboardWatcher(source: source, pollInterval: Self.neverAgain)
        let stream = await watcher.start()

        await source.put(text: "copied on Wayland")
        await source.notifyChange()

        let item = try #require(await next(stream)?.item)
        #expect(item.text == "copied on Wayland")
    }

    @Test("A spurious notification costs a counter read, not a duplicate entry")
    func spuriousNotificationCapturesNothing() async throws {
        let source = FakeClipboardSource(pushes: true)
        let watcher = ClipboardWatcher(source: source, pollInterval: Self.neverAgain)
        let stream = await watcher.start()

        // Both X11 and Wayland notify for selection-owner changes that leave
        // the contents alone. The counter is what tells them apart.
        await source.notifyChange()
        await source.notifyChange()

        await source.put(text: "the one real copy")
        await source.notifyChange()

        // Notifications are handled in order, so the decision arriving proves
        // the two spurious ones were already dealt with.
        let item = try #require(await next(stream)?.item)
        #expect(item.text == "the one real copy")
        #expect(await source.readCount == 1)
    }
}
