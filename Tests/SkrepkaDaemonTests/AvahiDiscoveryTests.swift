import Foundation
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// What the Avahi backend does when there is no `avahi-daemon` to talk to.
///
/// No live daemon anywhere in this suite, and that is what it is for. The
/// container this runs in has no avahi and no system bus, so every call below
/// exercises the failure path — which is the path a user on a machine without
/// the package actually takes, and the one nobody notices is broken until they
/// are on that machine.
@Suite("Avahi discovery without a responder")
struct AvahiDiscoveryTests {
    /// A socket path that cannot exist, under a directory that cannot exist.
    ///
    /// The point of naming one rather than passing `.system`: `.system` is the
    /// real system bus, so on any machine that runs avahi — the Steam Deck this
    /// project tests on, most desktop Linux — this suite would have talked to a
    /// live daemon and `advertisingFailsCleanly` would have published a real
    /// `_skrepka._tcp` record on the network. The build container has neither a
    /// bus nor avahi, which hid that everywhere except the one place it mattered.
    static let deadAddress = "/nonexistent/skrepka-tests/there-is-no-bus-here"

    /// A session pointed at a socket nothing is listening on, on every machine.
    static func deadSession() -> BusSession {
        BusSession(bus: .system, address: deadAddress)
    }

    @Test("probing without a daemon reports responderUnavailable, with a reason")
    func probeReportsNoResponder() async throws {
        let discovery = AvahiDiscovery(session: Self.deadSession())
        // No live-bus branch to allow for: ``deadAddress`` cannot be connected
        // to on any machine, so the no-responder path is the only path and an
        // answer of any other shape is a real failure.
        var failure: DiscoveryError?
        if case .failure(let value) = await discovery.probe() { failure = value }
        let error = try #require(failure, "a dead address cannot answer a probe")
        var reason: String?
        if case .responderUnavailable(let value) = error { reason = value }
        let named = try #require(
            reason, "a missing daemon must be responderUnavailable, not \(error)")
        // Named far enough to tell the user something true. "Why can I not see
        // my other machine" has several answers and an empty one is useless.
        #expect(!named.isEmpty)
        await discovery.stopEverything()
    }

    @Test("advertising without a responder fails and publishes nothing")
    func advertisingFailsCleanly() async throws {
        let discovery = AvahiDiscovery(session: Self.deadSession())
        let descriptor = ServiceDescriptor(
            displayName: "test",
            port: 7011,
            deviceID: try #require(SyncDeviceID(hex: String(repeating: "d", count: 64))),
            platform: .linux
        )
        await #expect(throws: DiscoveryError.self) {
            try await discovery.startAdvertising(descriptor)
        }
        // Nothing half-published. A registration readable after a failed
        // publish would have the daemon advertise a port it never bound.
        #expect(await discovery.registration == nil)
        await discovery.stopEverything()
    }

    @Test("a browse with no responder fails on the stream rather than throwing")
    func browsingFailsOnTheStream() async throws {
        let discovery = AvahiDiscovery(session: Self.deadSession())
        // `startBrowsing()` is not async — the protocol says so, because
        // `NWBrowser`'s failures arrive asynchronously too. A backend that
        // threw here and a backend that reported `.failed` would need two
        // different callers.
        let events = try await discovery.startBrowsing()
        var seen: DiscoveryEvent?
        for await event in events {
            seen = event
            break
        }
        guard case .failed(let error)? = seen else {
            Issue.record("expected a terminal failure, got \(String(describing: seen))")
            return
        }
        #expect(!error.description.isEmpty)
        await discovery.stopEverything()
    }

    /// The one rule this backend has to add, and the one thing about it that
    /// cannot be caught by reading the code: a typo in a match rule is not a
    /// compile error and not a runtime error either. `AddMatch` accepts a rule
    /// that matches nothing, and the daemon then restarts unnoticed for ever.
    @Test("the server-state match rule names avahi's server interface")
    func serverStateRuleIsWellFormed() {
        let rule = AvahiNames.BusDaemon.serverStateRule
        #expect(rule.contains("type='signal'"))
        #expect(rule.contains("sender='org.freedesktop.Avahi'"))
        #expect(rule.contains("interface='org.freedesktop.Avahi.Server'"))
        // Comma-separated key='value' pairs and nothing else; a stray space
        // around the separator is what dbus-daemon rejects.
        #expect(!rule.contains(", "))
    }

    /// A collision has to be worth more than one try, or two Steam Decks out of
    /// the box still cannot both publish.
    @Test("a publish tries more than one name")
    func collisionRetriesUnderAnotherName() {
        #expect(AvahiDiscovery.nameAttempts >= 2)
        #expect(AvahiNames.Server.alternativeServiceName == "GetAlternativeServiceName")
        #expect(AvahiNames.EntryGroup.reset == "Reset")
    }

    @Test("stopping twice is not an error")
    func stoppingIsIdempotent() async {
        let discovery = AvahiDiscovery(session: Self.deadSession())
        await discovery.stopEverything()
        await discovery.stopEverything()
        #expect(await discovery.registration == nil)
    }

    /// The check that a `Server.StateChanged` came from avahi, on the two
    /// answers that need no daemon: nothing to compare against, and a bus that
    /// cannot say who owns the name.
    ///
    /// The accepting case needs a live avahi, so it is not here — what is here
    /// is that the default is refusal. A directed signal is delivered whatever
    /// match rules say, so a check that failed open would let any local process
    /// drive a rebuild.
    @Test("a state change from nobody, or from an unknown sender, is refused")
    func serverStateFromAnUnknownSenderIsRefused() async {
        let discovery = AvahiDiscovery(session: Self.deadSession())
        // A signal the bus did not stamp with a sender at all.
        #expect(await discovery.isFromAvahi(nil) == false)
        // A unique name that cannot be confirmed, because the bus this session
        // points at does not exist. Unconfirmed is refused, not assumed.
        #expect(await discovery.isFromAvahi(":1.42") == false)
        // The well-known name never arrives in `sender` — the bus writes the
        // unique name there — so it must not be treated as avahi either.
        #expect(await discovery.isFromAvahi(AvahiNames.busName) == false)
        await discovery.stopEverything()
    }

}

/// The bound on rebuilding after an `avahi-daemon` restart — the one part of
/// the restart recovery that needs no bus to exercise.
@Suite("The avahi rebuild budget")
struct RecoveryBudgetTests {
    @Test("a budget allows exactly its limit of consecutive rebuilds")
    func theLimitBounds() {
        var budget = RecoveryBudget()
        for attempt in 1...RecoveryBudget.limit {
            // Called on its own line rather than inside `#expect`: the macro
            // rewrites its argument into a closure over an immutable `$0`, so a
            // `mutating` method cannot be called from within one.
            let spent = budget.spend()
            #expect(spent)
            #expect(budget.attempts == attempt)
        }
        #expect(budget.isExhausted)
        let spentWhenExhausted = budget.spend()
        #expect(spentWhenExhausted == false)
        // And stays where it is rather than counting a rebuild that was not
        // attempted.
        #expect(budget.attempts == RecoveryBudget.limit)
    }

    /// The defect this type exists for: one shared counter let the browse — which
    /// is rebuilt first and succeeds as soon as avahi hands out a browser —
    /// refill the budget before the republish had been tried at all, so an avahi
    /// crash-loop republished on every cycle and the bound never engaged.
    @Test("one half reaching a working state does not refill the other")
    func halvesDoNotVouchForEachOther() {
        var browse = RecoveryBudget()
        var publish = RecoveryBudget()
        for _ in 1...RecoveryBudget.limit {
            _ = browse.spend()
            _ = publish.spend()
        }
        browse.recordWorking()
        #expect(browse.attempts == 0)
        #expect(publish.isExhausted, "a browser that arrived says nothing about a publish")
    }

    @Test("a working state restores the full budget")
    func workingStateRefills() {
        var budget = RecoveryBudget()
        for _ in 1...RecoveryBudget.limit { _ = budget.spend() }
        budget.recordWorking()
        #expect(budget.attempts == 0)
        // Off its own line for the same reason as above: `#expect` rewrites its
        // argument into a closure over an immutable `$0`.
        let spentAfterRefill = budget.spend()
        #expect(spentAfterRefill)
    }
}

// MARK: - Why "only one responder exists" is not a test here
//
// The phase plan asks that the fallback path "does **not** run both responders
// at once", and there was a test called `exactlyOneResponderExists` that built
// a one-element array and asserted it had one element. That assertion cannot
// fail — it restates its own literal — so it proved the property held in the
// line above it and nothing about the build. Swift has no reflection that
// enumerates a protocol's conformances, so there is no honest version of it to
// write, and a test that cannot fail is worse than no test: it reads in a
// summary as coverage.
//
// The property still matters, so here is the reasoning it was carrying.
// `mdns.h` sets `SO_REUSEADDR` and `SO_REUSEPORT`, so co-binding UDP 5353 works
// for multicast — but **only one process receives unicast replies on that
// port**. An embedded responder started beside a live `avahi-daemon` therefore
// breaks discovery for both, which is why this build ships the avahi client and
// no responder of its own. Whoever adds `EmbeddedMDNSDiscovery` has to decide
// deliberately how the two coexist, and `AvahiDiscovery`'s own doc comment says
// the same thing at the place the decision would be made.
