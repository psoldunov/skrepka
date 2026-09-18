import Foundation
import SkrepkaCore

@testable import SkrepkaLinuxPlatform

/// What every suite driving a live backend needs from the reader it starts.
///
/// Both readers already have these methods; the protocol only names them, so
/// ``BackendHarness`` can start and stop either one through a single path.
protocol HeadlessReader: ClipboardSource {
    func start() async throws
    func stop() async
    func setSelection(_ payload: [String: Data]?, as write: SelectionWrite) async
}

extension DataControlReader: HeadlessReader {}
extension XFixesReader: HeadlessReader {}

/// Starts a backend over a headless session, and waits on it.
///
/// Lifted out of `WaylandBackendTests` and `X11BackendTests`, where it was
/// typed out once each, because `HandoffWriteTests` needs both halves and a
/// third copy is how the teardown order drifts.
enum BackendHarness {
    /// Gives a Wayland backend a headless Sway, and takes both away afterwards.
    static func withWayland<T>(
        _ label: String,
        _ body: (HeadlessSession, DataControlReader) async throws -> T
    ) async throws -> T {
        let session = try HeadlessSession(.sway, label: label)
        try session.start()
        let reader = DataControlReader(.wlrDataControl, displayName: session.waylandSocketPath)
        return try await run(reader, in: session, body)
    }

    /// Gives an X11 backend an Xvfb, and takes both away afterwards.
    static func withX11<T>(
        _ label: String,
        _ body: (HeadlessSession, XFixesReader) async throws -> T
    ) async throws -> T {
        let session = try HeadlessSession(.xvfb, label: label)
        try session.start()
        let reader = XFixesReader(displayName: session.x11Display)
        return try await run(reader, in: session, body)
    }

    /// Reader first, and *awaited*, before the session goes.
    ///
    /// Not `defer`, on either half. `defer` cannot `await`, so the only shape
    /// it allows is `defer { Task { await reader.stop() } }`, which merely
    /// spawns the teardown and returns: the compositor or the X server is then
    /// killed while the reader is still unbinding from it. Both readers'
    /// `stop()` waits rather than signals precisely so that cannot happen, and
    /// the suites are `.serialized` on the same assumption.
    private static func run<Reader: HeadlessReader, T>(
        _ reader: Reader,
        in session: HeadlessSession,
        _ body: (HeadlessSession, Reader) async throws -> T
    ) async throws -> T {
        do {
            try await reader.start()
        } catch {
            session.stop()
            throw error
        }

        do {
            let value = try await body(session, reader)
            await reader.stop()
            session.stop()
            return value
        } catch {
            await reader.stop()
            session.stop()
            throw error
        }
    }

    /// Waits for a reader's change counter to move past a known value.
    ///
    /// The counter rather than the notification stream, because the stream is
    /// what `ClipboardWatcher` consumes and a test that drained it would be
    /// competing with the thing it is meant to be proving.
    static func waitForChange(
        past previous: Int,
        on reader: some ClipboardSource,
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

    /// Pastes until another application reads `expected`, or gives up.
    ///
    /// A selection write is queued for the session's own loop, so the paste is
    /// retried until the compositor or the server has actually been told.
    static func pasteUntil(
        _ expected: String,
        from session: HeadlessSession,
        timeout: Duration = .seconds(5)
    ) async -> String? {
        var pasted: String?
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, pasted != expected {
            pasted = session.paste()
            if pasted != expected { try? await Task.sleep(for: .milliseconds(50)) }
        }
        return pasted
    }
}
