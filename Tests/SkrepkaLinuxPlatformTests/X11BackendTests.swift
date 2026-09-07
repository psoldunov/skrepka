import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaLinuxPlatform

/// The X11 backend against a real X server.
///
/// Xvfb, started by the test, carrying the XFIXES extension — so
/// `XFixesSelectSelectionInput` and `XFixesSelectionNotify` are doing real work
/// rather than being simulated. `xclip` is the other end, on both sides: it
/// puts clippings on for Skrepka to read, and it reads back the selection
/// Skrepka owns, which is the only way to assert the owner half without
/// grading Skrepka's homework with Skrepka's own pen.
///
/// Serialized so the container runs one X server at a time; correctness no
/// longer depends on it, because ``HeadlessSession`` hands the backend an
/// explicit display name instead of setting `DISPLAY` in this process.
@Suite("X11 XFIXES", .serialized, .enabled(if: HeadlessSession.isAvailable(.xvfb)))
struct X11BackendTests {
    private func withSession<T>(
        _ label: String,
        _ body: (HeadlessSession, XFixesReader) async throws -> T
    ) async throws -> T {
        let session = try HeadlessSession(.xvfb, label: label)
        try session.start()
        defer { session.stop() }

        let reader = XFixesReader(displayName: session.x11Display)
        try await reader.start()
        defer { Task { await reader.stop() } }
        return try await body(session, reader)
    }

    private func waitForChange(
        past previous: Int,
        on reader: XFixesReader,
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

    @Test("the probe picks XFIXES when there is no Wayland session")
    func probePicksX11() async throws {
        let session = try HeadlessSession(.xvfb, label: "probe")
        try session.start()
        defer { session.stop() }

        let report = SessionProbe().run(environment: session.probeEnvironment)
        #expect(report.backend == .xFixes)
        #expect(report.problem == nil)
        // A real X11 session, not XWayland: nothing to warn about.
        #expect(!report.isXWaylandFallback)
    }

    /// `UTF8_STRING` rather than a MIME type, which is what an ICCCM-era client
    /// offers and what would have been invisible without the atom aliases in
    /// ``LinuxRepresentationMap``.
    @Test("a copy under the X11 text atom is captured as text")
    func capturesUTF8String() async throws {
        try await withSession("text") { session, reader in
            let before = await reader.changeCount()
            #expect(session.copy("hello from xclip"))
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(CaptureRules().decide(snapshot).item?.text == "hello from xclip")
        }
    }

    /// A MIME-named target rather than an ICCCM atom, which is what every
    /// toolkit written since 2000 offers.
    ///
    /// The decision is `.rejectedEmpty`, and that is **not** a Linux fault: it
    /// is what `CaptureRules` does with rich text that carries no plain-text
    /// rendering, on either platform. `CaptureRules.text(for:payload:fileURLs:)`
    /// looks for `public.utf8-plain-text`, `public.url` and `public.file-url`
    /// and finds none, so the entry has no row label and no searchable body and
    /// is dropped. On macOS an application that writes HTML writes plain text
    /// beside it, so the case never arises; `xclip -t text/html` offers exactly
    /// one target, so on Linux it does.
    ///
    /// Asserted as it stands rather than fixed here: deriving plain text from
    /// HTML is a transformation, it changes what the macOS picker shows for a
    /// class of clips, and it belongs to whoever owns the capture rules rather
    /// than to the phase that ported the backend. What this test does prove is
    /// that the backend delivered the bytes.
    @Test("a MIME-named target reaches the snapshot, even where the rules drop it")
    func capturesMIMETarget() async throws {
        try await withSession("html") { session, reader in
            let before = await reader.changeCount()
            #expect(session.copy("<i>x</i>", mimeType: "text/html"))
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.html] == Data("<i>x</i>".utf8))
            #expect(snapshot.declaredTypes.contains("text/html"))
            #expect(CaptureRules().decide(snapshot) == .rejectedEmpty)
        }
    }

    /// The `INCR` path, on both sides at once — `xclip` sends large selections
    /// incrementally, so this is Skrepka draining a real `INCR` transfer rather
    /// than reading one property.
    @Test("a payload too large for one property arrives whole")
    func capturesIncrementally() async throws {
        try await withSession("incr") { session, reader in
            // Past the 256 KiB chunk both ends cap at, so the transfer is
            // several chunks however the other end sizes them.
            let text = String(repeating: "0123456789abcdef", count: 64 * 1024)
            let before = await reader.changeCount()
            let copied = session.copy(text)
            #expect(copied)
            #expect(await waitForChange(past: before, on: reader, timeout: .seconds(20)) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.string]?.count == text.utf8.count)
        }
    }

    /// The owner half. ICCCM makes `TARGETS`, `TIMESTAMP` and `MULTIPLE`
    /// mandatory of every selection owner; `xclip -o -t TARGETS` is what asks.
    @Test("a selection Skrepka owns advertises the required targets")
    func advertisesRequiredTargets() async throws {
        try await withSession("targets") { session, reader in
            await reader.setSelection(["UTF8_STRING": Data("owned".utf8)])

            var targets: String?
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, targets?.contains("TIMESTAMP") != true {
                targets = session.paste(mimeType: "TARGETS")
                if targets?.contains("TIMESTAMP") != true {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let advertised = targets ?? ""
            #expect(advertised.contains("TARGETS"))
            #expect(advertised.contains("TIMESTAMP"))
            #expect(advertised.contains("MULTIPLE"))
            #expect(advertised.contains("UTF8_STRING"))
        }
    }

    @Test("a selection Skrepka owns can be pasted by another application")
    func servesSelection() async throws {
        try await withSession("write") { session, reader in
            await reader.setSelection(["UTF8_STRING": Data("served by skrepka".utf8)])

            var pasted: String?
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline, pasted != "served by skrepka" {
                pasted = session.paste()
                if pasted != "served by skrepka" { try? await Task.sleep(for: .milliseconds(50)) }
            }
            #expect(pasted == "served by skrepka")
        }
    }

    /// The owner's own `INCR` path: a payload past one property's worth, read
    /// back by `xclip`, which drives the transfer by deleting the property
    /// between chunks.
    @Test("a large owned selection is served incrementally")
    func servesIncrementally() async throws {
        try await withSession("send-incr") { session, reader in
            let text = String(repeating: "abcdefgh", count: 128 * 1024)
            await reader.setSelection(["UTF8_STRING": Data(text.utf8)])

            var pasted: String?
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline, pasted?.count != text.count {
                pasted = session.paste()
                if pasted?.count != text.count { try? await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(pasted?.count == text.count)
            #expect(pasted == text)
        }
    }

    /// Skrepka's own paste-back arrives back as an `XFixesSelectionNotify` like
    /// anyone else's — the freedesktop convention has owners reacquire the
    /// selection whenever their content changes, precisely so XFIXES watchers
    /// notice, and Skrepka is both. What it must not do is read its own bytes
    /// back through a conversion, or report them as somebody else's copy.
    @Test("Skrepka's own selection comes back as its own bytes")
    func ownSelectionShortCircuits() async throws {
        try await withSession("self") { _, reader in
            let before = await reader.changeCount()
            await reader.setSelection(["UTF8_STRING": Data("mine".utf8)])
            #expect(await waitForChange(past: before, on: reader) != nil)

            guard case .contents(let snapshot) = await reader.read(sourceBundleID: nil) else {
                Issue.record("expected readable contents")
                return
            }
            #expect(snapshot.representations[PasteboardType.string] == Data("mine".utf8))
        }
    }

    @Test("changes arrive as notifications, so nothing has to poll")
    func notifies() async throws {
        try await withSession("notify") { session, reader in
            guard let stream = await reader.changeNotifications() else {
                Issue.record("XFIXES delivers real events, so this must not be nil")
                return
            }
            let counter = X11NotificationCounter()
            let pump = Task { for await _ in stream { await counter.bump() } }
            defer { pump.cancel() }

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

private actor X11NotificationCounter {
    private(set) var value = 0
    func bump() { value += 1 }
}
