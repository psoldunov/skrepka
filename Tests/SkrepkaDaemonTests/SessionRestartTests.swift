import Foundation
import SkrepkaLinuxPlatform
import Testing

@testable import SkrepkaDaemon

/// When a daemon that has never captured stops rebuilding its clipboard
/// session, and when it keeps going.
///
/// A refusal gives up after the delay list; a backend that only ran out of
/// time does not, because the next attempt may well get its first read in.
@Suite("Rebuilding the clipboard session")
struct SessionRestartTests {
    /// A started daemon with nothing to watch, so no retry is running yet.
    private static func idleDaemon() async throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-session-restart-\(UUID().uuidString)", directoryHint: .isDirectory)
        let daemon = try Daemon(options: options, environment: [:])
        try await daemon.start()
        return daemon
    }

    @Test("a backend that timed out is retried past the delay list, even before any capture")
    func timeoutKeepsRetrying() async throws {
        let daemon = try await Self.idleDaemon()
        #expect(await daemon.captureTask == nil)
        await daemon.scheduleSessionRestart(attempt: Daemon.sessionRetryDelays.count, isTransient: true)
        #expect(await daemon.captureTask != nil)
        await daemon.stop()
    }

    @Test("any other failure still gives up after the delay list when nothing was captured")
    func refusalGivesUp() async throws {
        let daemon = try await Self.idleDaemon()
        await daemon.scheduleSessionRestart(attempt: Daemon.sessionRetryDelays.count)
        #expect(await daemon.captureTask == nil)
        await daemon.stop()
    }

    @Test("only a timeout is transient, bare or wrapped as the backend's failure")
    func classifiesTimeouts() {
        let report = SessionProbe().run(environment: [:])
        #expect(Daemon.isTransient(LinuxSessionStartError.timedOut))
        #expect(
            Daemon.isTransient(
                ClipboardBackend.StartError.backendFailed(report, LinuxSessionStartError.timedOut)))
        #expect(!Daemon.isTransient(ClipboardBackend.StartError.unsupportedSession(report)))
        #expect(
            !Daemon.isTransient(LinuxSessionStartError.sessionFailed("This X server has no XFIXES extension"))
        )
        #expect(!Daemon.isTransient(LinuxSessionStartError.outOfFileDescriptors))
        #expect(!Daemon.isTransient(CancellationError()))
    }
}
