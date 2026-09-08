import SkrepkaIPC
import Testing

/// What ``BusSession`` reports about connections it has and has not opened.
///
/// Everything here runs against an address nothing can be listening on, which
/// is the only bus this suite can rely on: the build container has none, and a
/// developer machine or the Steam Deck this project tests on has a real one, so
/// a suite that reached for `.system` or `.session` would connect for real on
/// the machines that matter and prove nothing about the path it claims.
///
/// What that leaves untested, deliberately rather than by omission: the
/// reconnect itself. `BusSession` drops a connection when the parked task
/// unwinds, and making that happen needs a live bus to connect to and then
/// kill under the session — neither of which exists here. The counter's
/// zero-side is pinned below; its increment is not.
@Suite("Bus session lifetime")
struct BusSessionTests {
    /// A socket path that cannot exist, under a directory that cannot exist.
    static let deadAddress = "/nonexistent/skrepka-tests/there-is-no-bus-here"

    /// A session pointed at that address, on every machine.
    static func deadSession() -> BusSession {
        BusSession(bus: .session, address: deadAddress)
    }

    @Test("a session that has not connected has opened nothing")
    func generationStartsAtZero() async {
        let session = Self.deadSession()
        #expect(await session.generation == 0)
    }

    @Test("a connect that fails is not counted as an opened connection")
    func failedConnectDoesNotCount() async {
        let session = Self.deadSession()
        await #expect(throws: BusSession.SessionError.self) {
            _ = try await session.connection()
        }
        // The whole point of the counter is that a caller can compare it to
        // decide whether the state it built on the bus is gone. An attempt that
        // never reached a bus built nothing, so moving it would tell every
        // caller to throw away state that is still fine.
        #expect(await session.generation == 0)
        await session.stop()
    }

    @Test("repeated failures leave the count where it started")
    func repeatedFailuresDoNotCount() async {
        let session = Self.deadSession()
        for _ in 0..<3 {
            await #expect(throws: BusSession.SessionError.self) {
                _ = try await session.connection()
            }
        }
        // Note what this does not prove: a failed attempt left cached would
        // rethrow the same error, so the errors alone cannot tell a fresh
        // attempt from a corpse. The count is the claim being pinned here.
        #expect(await session.generation == 0)
        await session.stop()
    }

    @Test("stopping a session that never connected returns rather than parking")
    func stopWithoutConnectingIsANoOp() async {
        let session = Self.deadSession()
        // `stop()` cannot throw — the type says so — so what is being pinned is
        // that it completes: it awaits a parked task, and awaiting one that was
        // never started must not be a hang. A regression here shows up as this
        // test never finishing rather than as a failure.
        await session.stop()
        #expect(await session.generation == 0)
    }

    @Test("stop is idempotent")
    func stopIsIdempotent() async {
        let session = Self.deadSession()
        await session.stop()
        await session.stop()
        #expect(await session.generation == 0)
    }

    @Test("stop after a failed connect is idempotent too")
    func stopAfterFailureIsIdempotent() async {
        let session = Self.deadSession()
        await #expect(throws: BusSession.SessionError.self) {
            _ = try await session.connection()
        }
        // `connection()` unwinds its own failed attempt through `stop()`, so
        // these two are a second and third teardown of state already gone.
        await session.stop()
        await session.stop()
        #expect(await session.generation == 0)
    }

    @Test("a session stays usable after being stopped")
    func connectingAgainAfterStopStillReportsFailure() async throws {
        let session = Self.deadSession()
        await session.stop()
        // A `stop()` must leave the session able to open a fresh connection
        // rather than wedged: the address is still dead, so the observable
        // proof is that the call reaches a connect attempt and reports its
        // failure instead of hanging or reporting `cancelled`.
        var reported: BusSession.SessionError?
        do {
            _ = try await session.connection()
        } catch let error as BusSession.SessionError {
            reported = error
        } catch {
            Issue.record("expected a SessionError, got \(error)")
        }
        let error = try #require(reported, "a dead address cannot be connected to")
        guard case .cannotConnect = error else {
            Issue.record("a dead address must report cannotConnect, got \(error)")
            return
        }
        await session.stop()
    }
}
