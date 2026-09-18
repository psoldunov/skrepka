import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// The client half of the bus that a long-lived window uses, and the one
/// deadline that has to agree with the daemon's.
@Suite("Bus clients")
struct SkrepkaBusClientTests {
    /// A client that gave up on `PairWith` before the daemon did reported a
    /// timeout for a dial that was still running.
    @Test("a pairing call waits longer than the daemon's own dial deadline")
    func pairingCallOutlastsTheDial() {
        #expect(SkrepkaBus.pairingCallTimeout > Daemon.pairDialTimeout)
        #expect(SkrepkaBus.pairingCallTimeout > SkrepkaBus.callTimeout)
    }

    @Test("a session that cannot connect is the daemon-unavailable error, with its advice")
    func deadSessionIsDaemonUnavailable() async {
        // No `stop()` afterwards: a failed connect unwinds its own attempt —
        // see `BusSession.connection()`.
        let session = BusSession(bus: .session, address: BusNameClaimTests.deadAddress)
        do {
            _ = try await SkrepkaBus.proxy(on: session)
            Issue.record("a proxy on a dead address should not have been built")
        } catch let error as IPCError {
            guard case .daemonUnavailable = error else {
                Issue.record("expected daemonUnavailable, got \(error)")
                return
            }
            #expect(error.remedy != nil)
        } catch {
            Issue.record("expected an IPCError, got \(error)")
        }
    }
}
