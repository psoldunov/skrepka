import Foundation
import Synchronization
import Testing

@testable import SkrepkaDaemon

/// Shutdown finishes, and finishes promptly.
///
/// The bug behind this: `skrepkad` did its whole async teardown cleanly and
/// then hung in the C runtime's `exit`, so `systemctl stop` waited out
/// `TimeoutStopSec` and `SIGKILL`ed it. The process-exit half of that fix
/// (`_exit` in ``DaemonRunner``) cannot be a unit test — a test that called it
/// would kill the test runner — so the end-to-end proof is the SIGTERM repro.
///
/// What *is* reachable is the async half: ``Daemon/stop()`` must return, and
/// return quickly, even when sync came up against a machine with no system bus
/// (no avahi, no `org.freedesktop.Avahi`) — the exact state the daemon is in on
/// a headless box, and the state a shutdown that awaited a dead bus would hang
/// in. This guards that half against a future regression, e.g. a teardown step
/// that waits on a bus that will never answer.
@Suite("Daemon shutdown")
struct DaemonShutdownTests {
    @Test("stop() returns promptly after sync started without a bus")
    func stopReturnsPromptlyWithNoBus() async throws {
        var options = DaemonOptions()
        // Sync on, so `stop()` has to tear down the sync group, the listener,
        // discovery and the system-bus session — the steps a hang would be in.
        options.syncEnabled = true
        // Ephemeral, so parallel runs of this test do not collide on a port.
        options.port = 0
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-shutdown-\(UUID().uuidString)", directoryHint: .isDirectory)
        let daemon = try Daemon(options: options, environment: [:])

        // Bring-up steps over a clipboard backend the container lacks and a
        // system bus that is not there; neither is fatal, so this returns.
        try await daemon.start()

        // Poll a flag rather than `await stop()` directly, so a regression that
        // makes `stop()` hang fails this test at the deadline instead of
        // hanging the whole suite.
        let stopped = Atomic<Bool>(false)
        let stopper = Task {
            await daemon.stop()
            stopped.store(true, ordering: .releasing)
        }
        defer { stopper.cancel() }

        let clock = ContinuousClock()
        let began = clock.now
        let limit: Duration = .seconds(10)
        while !stopped.load(ordering: .acquiring), began.duration(to: clock.now) < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }

        // Read into a local first: `Atomic` is non-copyable and cannot be
        // captured by the `#expect` macro's autoclosure.
        let finished = stopped.load(ordering: .acquiring)
        #expect(finished, "daemon.stop() did not return within \(limit)")
    }
}
