import SkrepkaIPC
import Testing

/// What ``BusSession/invalidate()`` does, and — said plainly — what this suite
/// cannot reach.
///
/// Every session here points at an address nothing can be listening on, for the
/// reason `BusSessionTests` gives: the build container has no bus, and the
/// developer machine and the Steam Deck both have real ones, so a suite that
/// asked for `.system` or `.session` would connect for real on exactly the
/// machines that matter.
///
/// **The reconnect itself is not tested here, and no test below pretends
/// otherwise.** Proving that an `invalidate()` moves ``BusSession/generation``
/// and that the next call opens a *replacement* needs a live bus to connect to
/// and then kill under the session, which this suite has no way to obtain. What
/// is pinned is the half that is reachable without one: idempotence, the
/// no-connection no-op, and that a session stays usable across an invalidation.
/// The generation move is asserted in its zero-side form — an invalidation with
/// nothing to drop must *not* move it — and its increment is left honestly
/// unclaimed rather than dressed up in a test that would pass either way.
@Suite("Bus session invalidation")
struct BusSessionInvalidationTests {
    /// A session pointed at a socket that cannot exist, on every machine.
    static func deadSession() -> BusSession {
        BusSession(bus: .session, address: BusSessionTests.deadAddress)
    }

    @Test("invalidating a session that never connected is a no-op")
    func invalidateWithoutConnectingIsANoOp() async {
        let session = Self.deadSession()
        // Two claims: it returns rather than parking on a task that was never
        // started — a regression shows up as this test never finishing — and it
        // leaves the counter alone. Moving it here would tell every caller to
        // throw away state that nothing has invalidated.
        await session.invalidate()
        #expect(await session.generation == 0)
    }

    @Test("invalidate is idempotent")
    func invalidateIsIdempotent() async {
        let session = Self.deadSession()
        for _ in 0..<3 { await session.invalidate() }
        #expect(await session.generation == 0)
        await session.stop()
    }

    @Test("invalidating after a failed connect stays a no-op")
    func invalidateAfterFailedConnect() async {
        let session = Self.deadSession()
        await #expect(throws: BusSession.SessionError.self) {
            _ = try await session.connection()
        }
        // A connect that never reached a bus built nothing on it, so there is
        // nothing to invalidate and the counter must not move. `connection()`
        // has already unwound its own failed attempt through `stop()`, so this
        // is also the "nothing cached" path a second time.
        await session.invalidate()
        await session.invalidate()
        #expect(await session.generation == 0)
    }

    @Test("invalidate and stop are safe in either order")
    func invalidateAndStopCompose() async {
        let session = Self.deadSession()
        await session.invalidate()
        await session.stop()
        await session.invalidate()
        await session.stop()
        #expect(await session.generation == 0)
    }

    @Test("a session stays usable after being invalidated")
    func connectingAgainAfterInvalidateStillReportsFailure() async throws {
        let session = Self.deadSession()
        await session.invalidate()
        // This is the difference from `stop()` that matters: an invalidated
        // session is not finished, it is expected to reconnect. The address is
        // still dead, so the observable proof is that the call reaches a
        // connect attempt and reports its failure rather than hanging or
        // reporting `cancelled` — which is what a session left wedged would do.
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

    @Test("concurrent invalidations do not deadlock or double-count")
    func concurrentInvalidationsAreSafe() async {
        let session = Self.deadSession()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await session.invalidate() } }
        }
        // The counter is the only observable here, and nothing was connected,
        // so it must be untouched. The claim being pinned is that eight
        // concurrent invalidations complete at all: the teardown awaits a
        // parked task, and one that awaited a task another invalidation was
        // already awaiting would hang instead of failing.
        #expect(await session.generation == 0)
        await session.stop()
    }
}
