import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// The two orderings the daemon's lifecycle has to survive: a shutdown that
/// begins while bring-up is suspended, and a watcher that is replaced while one
/// of its failures is already in flight.
///
/// Both are races the actor alone does not settle — re-entrancy across an
/// `await` is what ``Daemon/enqueue(_:)`` exists for, and a cancelled task can
/// still deliver an element it has already taken off a stream.
@Suite("The daemon lifecycle is ordered")
struct DaemonLifecycleTests {
    static func daemon() throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-lifecycle-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:])
    }

    /// `start()` runs on the same queue as `stop()`, so a start that loses the
    /// race finds the daemon already stopped and brings nothing up.
    ///
    /// Unqueued, `start()` suspended inside `startClipboard()` and again inside
    /// `startSync()`, so a shutdown could run to completion in between and then
    /// have discovery started behind it — a listener and a published record
    /// nothing would ever tear down.
    ///
    /// ``Daemon/sessionReport`` is the tell: ``Daemon/startClipboard()`` writes
    /// it before its first `await`, so a nil one means bring-up did not begin.
    @Test("a start that arrives after a stop does not bring the daemon back up")
    func startAfterStopStaysDown() async throws {
        let daemon = try Self.daemon()
        await daemon.stop()
        try await daemon.start()
        #expect(await daemon.sessionReport == nil)
        #expect(await daemon.captureTask == nil)
    }

    @Test("a loss from a replaced advertisement watcher is ignored")
    func staleAdvertisementLossIsIgnored() async throws {
        let daemon = try Self.daemon()
        let stale = await daemon.nextAdvertisementGeneration()
        _ = await daemon.nextAdvertisementGeneration()
        await daemon.pretendPublished()

        await daemon.advertisementLost(
            .advertisingLost(reason: "the entry group collided"), generation: stale)

        // The republish that replaced it is still healthy, and `skrepka doctor`
        // has nothing to report.
        #expect(await daemon.isPublished)
        #expect(await daemon.responderProblem == nil)
    }

    @Test("a loss from the live advertisement watcher is reported")
    func liveAdvertisementLossIsReported() async throws {
        let daemon = try Self.daemon()
        _ = await daemon.nextAdvertisementGeneration()
        let live = await daemon.nextAdvertisementGeneration()
        await daemon.pretendPublished()

        await daemon.advertisementLost(
            .advertisingLost(reason: "the entry group collided"), generation: live)

        #expect(await daemon.isPublished == false)
        #expect(await daemon.responderProblem != nil)
    }
}

extension Daemon {
    /// Puts the daemon in the state a successful publish leaves it in.
    ///
    /// Here rather than in the target: reaching it for real needs a live
    /// `avahi-daemon` and a bound listener, and the ordering under test is
    /// entirely between ``Daemon/advertisementGeneration`` and the failures a
    /// replaced watcher may still deliver.
    func pretendPublished() {
        isPublished = true
        responderProblem = nil
    }
}
