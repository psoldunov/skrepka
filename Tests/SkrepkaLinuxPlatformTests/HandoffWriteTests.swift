import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaLinuxPlatform

/// A peer's live push, written to a real clipboard, never comes back as a
/// capture.
///
/// The daemon used to pause the watcher around the write and resume it
/// straight after. That never covered the echo: `setSelection` only queues a
/// command for the session's loop, the compositor or the server answers with a
/// selection event some time later, and by then the watcher was running
/// again — so every push this machine received was recorded as a local copy
/// and pushed back out. These tests hold the session to the replacement: a
/// ``SelectionWrite/handoff`` write is remembered beside the payload it
/// serves, and its own echo moves nothing.
///
/// Each test is gated on its own tool, so a container with only one of Sway
/// and Xvfb still runs the half it can.
@Suite("Handoff writes", .serialized)
struct HandoffWriteTests {
    private static let waylandText = "text/plain;charset=utf-8"
    private static let x11Text = "UTF8_STRING"

    // MARK: - Echo

    @Test(
        "a handoff on Wayland leaves the counter to the next real copy",
        .enabled(if: HeadlessSession.isAvailable(.sway))
    )
    func waylandHandoffIsNotAChange() async throws {
        try await BackendHarness.withWayland("handoff-echo") { session, reader in
            try await assertOnlyTheNextCopyCounts(
                session: session, reader: reader, target: Self.waylandText
            )
        }
    }

    @Test(
        "a handoff on X11 leaves the counter to the next real copy",
        .enabled(if: HeadlessSession.isAvailable(.xvfb))
    )
    func x11HandoffIsNotAChange() async throws {
        try await BackendHarness.withX11("handoff-echo") { session, reader in
            try await assertOnlyTheNextCopyCounts(
                session: session, reader: reader, target: Self.x11Text
            )
        }
    }

    /// Hands a payload over, then copies from another application.
    ///
    /// The paste that proves the handoff landed also proves its echo has been
    /// dealt with: both protocols deliver events in order on one connection,
    /// and the session's own selection event was sent before the paste's
    /// request to read it — so by the time `wl-paste` or `xclip` has the bytes,
    /// the loop has already decided what to do with the echo.
    private func assertOnlyTheNextCopyCounts(
        session: HeadlessSession,
        reader: some HeadlessReader,
        target: String
    ) async throws {
        let before = await reader.changeCount()
        await reader.setSelection([target: Data("handed over".utf8)], as: .handoff)
        #expect(await BackendHarness.pasteUntil("handed over", from: session) == "handed over")
        #expect(await reader.changeCount() == before)

        #expect(session.copy("copied after"))
        let after = await BackendHarness.waitForChange(past: before, on: reader)
        #expect(after == before + 1)
        // Long enough for a second event to land if the copy produced one.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await reader.changeCount() == before + 1)

        let read = await reader.read(sourceBundleID: nil)
        guard case .contents(let snapshot) = read else {
            Issue.record("expected readable contents, got \(read)")
            return
        }
        #expect(CaptureRules().decide(snapshot).item?.text == "copied after")
    }

    /// Replacing a source Skrepka is serving makes a Wayland compositor clear
    /// the selection before it reports the new one. That clear used to be
    /// published as an empty clipboard, so a handoff over Skrepka's own copy
    /// moved the counter after all.
    @Test(
        "a handoff over Skrepka's own copy on Wayland is not a change",
        .enabled(if: HeadlessSession.isAvailable(.sway))
    )
    func waylandHandoffOverOwnCopyIsNotAChange() async throws {
        try await BackendHarness.withWayland("handoff-over-copy") { session, reader in
            try await assertHandoffOverOwnCopyMovesNothing(
                session: session, reader: reader, target: Self.waylandText
            )
        }
    }

    @Test(
        "a handoff over Skrepka's own copy on X11 is not a change",
        .enabled(if: HeadlessSession.isAvailable(.xvfb))
    )
    func x11HandoffOverOwnCopyIsNotAChange() async throws {
        try await BackendHarness.withX11("handoff-over-copy") { session, reader in
            try await assertHandoffOverOwnCopyMovesNothing(
                session: session, reader: reader, target: Self.x11Text
            )
        }
    }

    /// Copies, waits for the copy's own report, then hands a payload over on
    /// top of it. The paste orders the handoff's events before the check, as
    /// in ``assertOnlyTheNextCopyCounts(session:reader:target:)``.
    private func assertHandoffOverOwnCopyMovesNothing(
        session: HeadlessSession,
        reader: some HeadlessReader,
        target: String
    ) async throws {
        let before = await reader.changeCount()
        await reader.setSelection([target: Data("copied here".utf8)], as: .copy)
        #expect(await BackendHarness.waitForChange(past: before, on: reader) == before + 1)

        await reader.setSelection([target: Data("handed over".utf8)], as: .handoff)
        #expect(await BackendHarness.pasteUntil("handed over", from: session) == "handed over")
        // Long enough for a late event to land if the handoff produced one.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await reader.changeCount() == before + 1)
    }

    // MARK: - Still a clipboard

    @Test(
        "a handoff on Wayland can be pasted by another application",
        .enabled(if: HeadlessSession.isAvailable(.sway))
    )
    func waylandHandoffIsPasteable() async throws {
        try await BackendHarness.withWayland("handoff-paste") { session, reader in
            await reader.setSelection([Self.waylandText: Data("from a peer".utf8)], as: .handoff)
            #expect(await BackendHarness.pasteUntil("from a peer", from: session) == "from a peer")
        }
    }

    @Test(
        "a handoff on X11 can be pasted by another application",
        .enabled(if: HeadlessSession.isAvailable(.xvfb))
    )
    func x11HandoffIsPasteable() async throws {
        try await BackendHarness.withX11("handoff-paste") { session, reader in
            await reader.setSelection([Self.x11Text: Data("from a peer".utf8)], as: .handoff)
            #expect(await BackendHarness.pasteUntil("from a peer", from: session) == "from a peer")
        }
    }

    // MARK: - What the watcher sees

    @Test(
        "the watcher over Wayland records the copy after a handoff, not the handoff",
        .enabled(if: HeadlessSession.isAvailable(.sway))
    )
    func waylandWatcherSkipsHandoff() async throws {
        try await BackendHarness.withWayland("handoff-watch") { session, reader in
            try await assertWatcherSkipsHandoff(
                session: session, reader: reader, target: Self.waylandText
            )
        }
    }

    @Test(
        "the watcher over X11 records the copy after a handoff, not the handoff",
        .enabled(if: HeadlessSession.isAvailable(.xvfb))
    )
    func x11WatcherSkipsHandoff() async throws {
        try await BackendHarness.withX11("handoff-watch") { session, reader in
            try await assertWatcherSkipsHandoff(
                session: session, reader: reader, target: Self.x11Text
            )
        }
    }

    /// `ClipboardWatcher` is what the daemon actually runs, with no pause
    /// around the write — the first decision it produces has to be the copy
    /// that followed, because decisions arrive in the order the changes did.
    private func assertWatcherSkipsHandoff(
        session: HeadlessSession,
        reader: some HeadlessReader,
        target: String
    ) async throws {
        let watcher = ClipboardWatcher(source: reader)
        let decisions = await watcher.start()
        let log = DecisionLog()
        let pump = Task { for await decision in decisions { await log.append(decision) } }
        defer { pump.cancel() }

        await reader.setSelection([target: Data("handed over".utf8)], as: .handoff)
        #expect(await BackendHarness.pasteUntil("handed over", from: session) == "handed over")
        #expect(session.copy("copied after"))

        let first = await log.first(within: .seconds(5))
        #expect(first?.item?.text == "copied after")
        await watcher.stop()
    }
}

/// Collects a watcher's decisions from a background task, so a test can wait
/// for the first one with a deadline rather than block on the stream.
private actor DecisionLog {
    private var decisions: [CaptureDecision] = []

    func append(_ decision: CaptureDecision) { decisions.append(decision) }

    func first(within timeout: Duration) async -> CaptureDecision? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while decisions.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return decisions.first
    }
}
