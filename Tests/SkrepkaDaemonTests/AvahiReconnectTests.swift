import Testing

@testable import SkrepkaLinuxPlatform

/// The rule a server watch *would* apply if it noticed the bus underneath it
/// being replaced, rather than avahi.
///
/// Every test here calls ``AvahiDiscovery/ending(builtOn:now:avahi:)`` directly.
/// That is deliberate and it is the limit of what is claimed: the function is
/// pure, and these cases pin down the decision it makes. They say nothing about
/// whether anything reaches it, and today nothing does — the reconnect trigger
/// it was written for is dormant, for the reason set out at the top of
/// `Sources/SkrepkaLinuxPlatform/Discovery/AvahiDiscovery+Reconnect.swift`. Read
/// a green run here as "the rule is right", never as "a bus restart recovers".
@Suite("The avahi bus-reconnect decision")
struct AvahiReconnectTests {
    /// A watch that ended on the connection its state was built on did not lose
    /// anything, and must not spend a rebuild finding that out.
    @Test("a stream that ended without the connection changing rebuilds nothing")
    func sameConnectionResubscribes() {
        #expect(AvahiDiscovery.ending(builtOn: 3, now: 3, avahi: .running) == .resubscribe)
        // And the same answer whatever avahi says, because avahi's state is not
        // what is being asked about.
        #expect(AvahiDiscovery.ending(builtOn: 3, now: 3, avahi: nil) == .resubscribe)
        #expect(AvahiDiscovery.ending(builtOn: 3, now: 3, avahi: .registering) == .resubscribe)
    }

    /// The convergence rule: avahi already `RUNNING` at the moment a new
    /// subscription went in would mean its `StateChanged` was emitted before
    /// there was anyone to hear it, leaving the reconnect side the only one that
    /// could act. This is the arithmetic of that, not a run of it.
    @Test("a replaced connection with avahi already up rebuilds here")
    func replacedConnectionWithAvahiUpRebuilds() {
        #expect(AvahiDiscovery.ending(builtOn: 1, now: 2, avahi: .running) == .rebuild)
    }

    /// The other half of the same rule. avahi still coming up means the
    /// `RUNNING` it has yet to emit would land on the subscription now in place
    /// and drive the rebuild from there. Answering `.rebuild` as well is the
    /// double spend; answering it *instead* would build onto a daemon that is
    /// not ready.
    @Test("a replaced connection with avahi not up yet waits for its RUNNING")
    func replacedConnectionWithoutAvahiWaits() {
        // Cannot answer at all — the ordinary case, because avahi restarts with
        // the bus and is not back when the reconnect happens.
        #expect(AvahiDiscovery.ending(builtOn: 1, now: 2, avahi: nil) == .waitForAvahi)
        // Answering, and not ready. Every non-running state waits.
        for state in [
            AvahiNames.ServerState.invalid, .registering, .collision, .failure,
        ] {
            #expect(AvahiDiscovery.ending(builtOn: 1, now: 2, avahi: state) == .waitForAvahi)
        }
    }

    /// The first connection is a change from ``AvahiDiscovery/busGeneration``'s
    /// zero, and would read as a reconnect if the loop asked. It does not —
    /// the first pass only records — but the numbering has to be the one
    /// `BusSession` documents or the comparison means nothing.
    @Test("a first connection is generation one, against a recorded zero")
    func theFirstConnectionIsAChangeFromZero() {
        #expect(AvahiDiscovery.ending(builtOn: 0, now: 1, avahi: .running) == .rebuild)
    }

    /// Reaching for a bus that is not there has to stop, and has to pause
    /// between tries — a reconnect loop with neither is a spin on a machine
    /// with no `dbus-daemon` at all.
    @Test("reconnecting is bounded and paced")
    func reconnectingIsBounded() {
        #expect(AvahiDiscovery.reconnectAttempts >= 2)
        #expect(AvahiDiscovery.reconnectDelay > .zero)
    }

    /// `GetState` is asked for by name over the wire, so a typo is a refused
    /// call at runtime and nothing at all at compile time. Signature from
    /// avahi 0.8's `org.freedesktop.Avahi.Server.xml`: `() -> i`, an
    /// `AvahiServerState`.
    @Test("the state avahi is asked for is spelled the way avahi spells it")
    func serverStateIsAskedForByName() {
        #expect(AvahiNames.Server.getState == "GetState")
        // The value that decides the rebuild, from `avahi-common/defs.h`.
        #expect(AvahiNames.ServerState.running.rawValue == 2)
    }
}

// MARK: - What is not covered here, and why
//
// The failure mode being guarded against is already on record in this repo: a
// test helper whose docstring claimed a dead address while it used the real
// system bus, and published a real `_skrepka._tcp` record from a test run. So
// these are stated plainly rather than left to be inferred from a green suite.
//
// - **No bus restart is exercised, and none can be.** Not because the harness
//   lacks a bus, but because `runServerWatch()`'s trigger does not fire at all:
//   its signal stream finishes only in `DBusClient.Connection.deinit`
//   (`.build-linux/checkouts/dbus/Sources/DBUS/DBusClient.swift:70-77`), and
//   both `BusSession`'s cached connection and the parked closure's own
//   parameter keep that object alive while the bus is dead. A test that
//   restarted a real `dbus-daemon` would therefore hang rather than pass. The
//   file header on `AvahiDiscovery+Reconnect.swift` carries the full finding.
//
// - **`discardEntryGroup(at:)` is not exercised.** It is reached when
//   `EntryGroupNew` succeeds and `AddService` or `Commit` then fails, so it
//   needs an avahi that hands out a group and refuses what is added to it. On a
//   dead session `EntryGroupNew` never succeeds, so a test written against one
//   would assert on a path it never entered and could not fail.
//   `advertisingFailsCleanly` in `AvahiDiscoveryTests.swift` covers as much as a
//   machine with no responder can: a publish that failed leaves no registration
//   behind.
//
// - **What the suite above does prove.** That `ending(builtOn:now:avahi:)`
//   returns the right answer for every combination of a moved generation and an
//   avahi state — including the `GetState` convergence that stops one
//   `dbus-daemon` restart costing two rebuilds. That rule is the part worth
//   pinning down, and it will be correct on the day something calls it.
