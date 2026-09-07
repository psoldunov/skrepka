import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaLinuxPlatform

/// The Wayland backend against a real compositor.
///
/// Headless Sway, started by the test, advertising
/// `zwlr_data_control_manager_v1` version 2 — so this is
/// ``WlrDataControlBinding`` driving live protocol traffic rather than a
/// simulation of it. `wl-copy` and `wl-paste` are the other end, deliberately:
/// a test where Skrepka is on both sides only proves it agrees with itself.
///
/// `ext-data-control-v1` has no compositor here — Sway 1.9 is wlroots 0.17,
/// which predates it. It runs the same engine through the same seam, and stays
/// **unverified against a live compositor** until the Steam Deck's 3.9 preview
/// channel or a newer Sway is available.
///
/// Serialized so the container runs one compositor at a time rather than eight;
/// correctness no longer depends on it, because ``HeadlessSession`` hands the
/// backend an absolute socket path instead of setting `WAYLAND_DISPLAY` in this
/// process.
@Suite("Wayland data control", .serialized, .enabled(if: HeadlessSession.isAvailable(.sway)))
struct WaylandBackendTests {
    /// Gives a backend a compositor, and takes both away afterwards.
    private func withSession<T>(
        _ label: String,
        _ body: (HeadlessSession, DataControlReader) async throws -> T
    ) async throws -> T {
        let session = try HeadlessSession(.sway, label: label)
        try session.start()
        defer { session.stop() }

        let reader = DataControlReader(.wlrDataControl, displayName: session.waylandSocketPath)
        try await reader.start()
        defer { Task { await reader.stop() } }
        return try await body(session, reader)
    }

    /// Waits for the reader's change counter to move past a known value.
    ///
    /// The counter rather than the notification stream, because the stream is
    /// what `ClipboardWatcher` consumes and a test that drained it would be
    /// competing with the thing it is meant to be proving.
    private func waitForChange(
        past previous: Int,
        on reader: DataControlReader,
        timeout: Duration = .seconds(5)
    ) async -> Int? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let current = await reader.changeCount()
            if current > previous { return current }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("the probe finds wlr-data-control on a headless Sway")
    func probeFindsWlr() async throws {
        let session = try HeadlessSession(.sway, label: "probe")
        try session.start()
        defer { session.stop() }

        let report = SessionProbe().run(environment: session.probeEnvironment)
        #expect(report.waylandGlobals.contains(SessionProbe.wlrGlobal))
        #expect(report.backend == .wlrDataControl)
        // Sway 1.9 is wlroots 0.17. If this ever fails, the container's sway
        // moved past 0.19 and `ExtDataControlBinding` has a compositor at last.
        #expect(!report.waylandGlobals.contains(SessionProbe.extGlobal))
        #expect(report.problem == .deprecatedProtocolOnly)
    }

    @Test("a copy from another application is captured as text")
    func capturesText() async throws {
        try await withSession("text") { session, reader in
            let before = await reader.changeCount()
            #expect(session.copy("hello from wl-copy"))
            let after = await waitForChange(past: before, on: reader)
            #expect(after != nil)

            let read = await reader.read(sourceBundleID: nil)
            guard case .contents(let snapshot) = read else {
                Issue.record("expected readable contents, got \(read)")
                return
            }
            #expect(
                snapshot.representations[PasteboardType.string]
                    .map { String(bytes: $0, encoding: .utf8) } == "hello from wl-copy"
            )
            #expect(CaptureRules().decide(snapshot).item?.text == "hello from wl-copy")
        }
    }

    @Test("a copy of HTML is captured as rich text")
    func capturesHTML() async throws {
        try await withSession("html") { session, reader in
            let before = await reader.changeCount()
            #expect(session.copy("<b>bold</b>", mimeType: "text/html"))
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.html] == Data("<b>bold</b>".utf8))
            #expect(CaptureRules().decide(snapshot).item?.kind == .richText)
        }
    }

    /// The privacy path against a live compositor.
    ///
    /// `wl-copy --sensitive` would be the natural way to write this — it is
    /// what a password manager does — but wl-clipboard **2.2.1**, which is what
    /// Ubuntu noble ships and therefore what the build image carries, has no
    /// such flag: `wl-copy --help` lists only `-o -f -c -p -n -t -s -v -h`. So
    /// the hint is set as the sole target instead, which still exercises the
    /// live path that matters — the hint is received through a real pipe and
    /// its *value* decides the outcome.
    ///
    /// The realistic shape, a hint offered alongside the text it conceals, is
    /// covered by `LinuxSnapshotBuilderTests`: `wl-copy` can only offer one
    /// target per invocation, so no version of it could set up that clipboard.
    @Test("the KDE hint is honoured by value, over a real pipe")
    func honoursPasswordHint() async throws {
        try await withSession("secret") { session, reader in
            let before = await reader.changeCount()
            #expect(session.copy("secret", mimeType: PrivacyMarkers.kdePasswordManagerHint))
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let rejected) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(CaptureRules().decide(rejected) == .rejectedPrivacyMarker)
            // Nothing was read: the hint is checked before any representation.
            #expect(rejected.representations.isEmpty)

            // The same target with any other value means the opposite. Klipper
            // stores an entry hinted `public` normally, and rejecting on the
            // bare presence of the target would drop every clip a KDE
            // application labelled.
            let marked = await reader.changeCount()
            #expect(session.copy("public", mimeType: PrivacyMarkers.kdePasswordManagerHint))
            #expect(await waitForChange(past: marked, on: reader) != nil)

            guard case .contents(let stored) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(CaptureRules().decide(stored) != .rejectedPrivacyMarker)
        }
    }

    @Test("a large payload survives the pipe intact")
    func capturesLargePayload() async throws {
        try await withSession("large") { session, reader in
            // Comfortably past a pipe's 64 KiB buffer, so the transfer takes
            // several passes of the poll loop and a deadlock would show.
            let text = String(repeating: "0123456789abcdef", count: 64 * 1024)
            let before = await reader.changeCount()
            // Assigned first rather than inlined: a failed `#expect` renders
            // every operand, and a megabyte of them buries the whole test log.
            let copied = session.copy(text)
            #expect(copied)
            #expect(await waitForChange(past: before, on: reader, timeout: .seconds(10)) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.string]?.count == text.utf8.count)
        }
    }

    /// The other half of "done when": a selection another application can
    /// paste. Asserted with `wl-paste`, which knows nothing about Skrepka.
    @Test("a selection Skrepka owns can be pasted by another application")
    func servesSelection() async throws {
        try await withSession("write") { session, reader in
            await reader.setSelection([
                "text/plain;charset=utf-8": Data("served by skrepka".utf8),
                "text/plain": Data("served by skrepka".utf8),
            ])
            // The set is queued for the loop, so the paste is retried until the
            // compositor has actually been told.
            var pasted: String?
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, pasted != "served by skrepka" {
                pasted = session.paste()
                if pasted != "served by skrepka" { try? await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(pasted == "served by skrepka")
        }
    }

    /// Skrepka's own paste-back must not come back as a fresh capture from an
    /// unknown application — and when it does come back, it must carry the
    /// bytes Skrepka put there rather than an empty snapshot.
    @Test("Skrepka's own selection is served from what it already holds")
    func ownSelectionShortCircuits() async throws {
        try await withSession("self") { _, reader in
            let before = await reader.changeCount()
            await reader.setSelection(["text/plain;charset=utf-8": Data("mine".utf8)])
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.string] == Data("mine".utf8))
        }
    }

    /// What `ClipboardWatcher` actually consumes. A backend whose counter moves
    /// but whose stream stays silent would look fine to every test above and
    /// capture nothing in the app, because the watcher runs no timer here.
    @Test("changes arrive as notifications, so nothing has to poll")
    func notifies() async throws {
        try await withSession("notify") { session, reader in
            guard let stream = await reader.changeNotifications() else {
                Issue.record("a Wayland backend must offer notifications")
                return
            }
            let counter = NotificationCounter()
            let pump = Task { for await _ in stream { await counter.bump() } }
            defer { pump.cancel() }

            // `start()` publishes the clipboard's existing contents, so the
            // stream already holds one notification before the test does
            // anything — `AsyncStream.makeStream()` buffers without bound.
            // Draining it first is what makes the assertion about the copy.
            try? await Task.sleep(for: .milliseconds(300))
            let before = await counter.value
            #expect(session.copy("notify me"))

            var notified = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, !notified {
                notified = await counter.value > before
                if !notified { try? await Task.sleep(for: .milliseconds(20)) }
            }
            #expect(notified)
        }
    }
}

/// Counts notifications from a background task, so a test can assert one
/// arrived *after* a particular moment rather than at all.
private actor NotificationCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
