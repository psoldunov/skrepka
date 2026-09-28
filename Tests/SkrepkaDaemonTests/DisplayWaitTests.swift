import Foundation
import Testing

@testable import SkrepkaDaemon

/// A daemon that starts before the desktop exported a display waits for one,
/// instead of capturing nothing for the whole session.
///
/// Plasma's login is that case: `skrepkad.service` is wanted by
/// `default.target`, which the user manager reaches before KWin runs.
@Suite("The daemon waits for a display")
struct DisplayWaitTests {
    /// A Wayland display name nothing listens on, so the probe that follows
    /// the wait finds no compositor and never reaches the test machine's.
    private static let absentDisplay = "skrepka-test-no-such-display"

    /// Answers each read with the next of `answers`, then repeats the last.
    private actor Manager {
        private var answers: [[String: String]?]
        private(set) var reads = 0
        private(set) var isClosed = false

        init(answers: [[String: String]?]) { self.answers = answers }

        func read() -> [String: String]? {
            reads += 1
            return answers.count > 1 ? answers.removeFirst() : answers.first.flatMap { $0 }
        }

        func close() { isClosed = true }

        nonisolated var source: UserManagerSource {
            UserManagerSource(read: { await self.read() }, close: { await self.close() })
        }
    }

    private static func daemon(
        environment: [String: String], userManager: UserManagerSource? = nil
    ) throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-display-wait-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: environment, userManager: userManager)
    }

    @Test("with a user-manager bus and no display, start leaves a wait running")
    func waitsWhenABusIsNamed() async throws {
        // A socket that cannot exist: every read fails, so the wait keeps going
        // without ever reaching the bus of the machine running the test.
        let daemon = try Self.daemon(environment: [
            "DBUS_SESSION_BUS_ADDRESS": "unix:path=/nonexistent/skrepka-test-bus"
        ])
        try await daemon.start()
        #expect(await daemon.isWaitingForDisplay)
        #expect(await daemon.captureTask != nil)
        await daemon.stop()
    }

    @Test("with no bus to ask, the empty session is stepped over as before")
    func stepsOverWithoutABus() async throws {
        let daemon = try Self.daemon(environment: [:])
        try await daemon.start()
        #expect(await !daemon.isWaitingForDisplay)
        #expect(await daemon.captureTask == nil)
        await daemon.stop()
    }

    @Test("once the manager names a display, capture is tried on it and the manager let go")
    func takesTheManagersDisplay() async throws {
        let manager = Manager(answers: [
            nil, ["WAYLAND_DISPLAY": Self.absentDisplay, "XDG_SESSION_TYPE": "wayland", "PATH": "/x"],
        ])
        let daemon = try Self.daemon(environment: [:], userManager: manager.source)
        try await daemon.start()
        #expect(await daemon.isWaitingForDisplay)

        // Two reads: nothing after one second, the display after two more.
        let deadline = ContinuousClock.now + .seconds(15)
        while !(await manager.isClosed), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await manager.isClosed)
        // The check runs on the lifecycle queue; this lands behind it.
        await daemon.enqueue { _ in }.value

        #expect(await manager.reads == 2)
        #expect(await daemon.sessionEnvironment["WAYLAND_DISPLAY"] == Self.absentDisplay)
        #expect(await daemon.sessionEnvironment["PATH"] == nil)
        #expect(await !daemon.isWaitingForDisplay)
        await daemon.stop()
    }

    @Test("a stop while the wait is pending leaves nothing asking")
    func stopEndsTheWait() async throws {
        let manager = Manager(answers: [nil])
        let daemon = try Self.daemon(environment: [:], userManager: manager.source)
        try await daemon.start()
        await daemon.stop()
        #expect(await daemon.captureTask == nil)
        #expect(await manager.isClosed)
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(await manager.reads == 0)
    }
}
