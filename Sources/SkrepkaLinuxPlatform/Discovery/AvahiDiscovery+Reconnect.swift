import DBUS
import Foundation
import Logging
// For `BusSession.generation`. Swift 6's MemberImportVisibility needs the
// module that declares a member imported here, not merely somewhere in the
// target.
import SkrepkaIPC

/// Surviving a `dbus-daemon` restart, as opposed to an `avahi-daemon` one.
///
/// `AvahiDiscovery+Recovery.swift` covers avahi going away and coming back. This
/// covers the bus underneath it going away, which is the worse of the two: a
/// restarted `dbus-daemon` takes avahi's `ServiceBrowser` and `EntryGroup` with
/// it *and* takes the connection every subscription was made on, so the
/// `Server.StateChanged` that would have reported the recovery arrives on a
/// socket nobody is reading. Reconnecting to the bus alone is not enough —
/// that produces a live connection holding a dead browser and a path to an entry
/// group avahi has already reclaimed.
///
/// ## Which trigger fires today, and which does not
///
/// **`Server.StateChanged` works, and it is the common case.** An
/// `avahi-daemon` that restarts on its own — `systemctl restart avahi-daemon`,
/// or an ordinary package upgrade — leaves the session bus up, so the
/// subscription taken in ``AvahiDiscovery/runServerWatch()`` survives and the
/// new daemon's `RUNNING` arrives on it. That path is live, and it is the one
/// `AvahiDiscovery+Recovery.swift` was built for.
///
/// **The watch-ending path below is dormant.** It is written against a
/// `dbus-daemon` restart, where the reconnect would show up as the signal
/// stream finishing — and with the `dbus` package this repo resolves, that
/// stream never finishes. `Connection.deinit` is the only thing that finishes
/// an entry in `signalSubscribers`
/// (`.build-linux/checkouts/dbus/Sources/DBUS/DBusClient.swift:70-77`; a
/// `grep -n signalSubscribers` over that file gives 56, 74, 109, 224, 233, and
/// 74 is the deinit). The `Connection` is held by two live references for as
/// long as the bus is dead — `BusSession`'s cached connection, and the
/// `connection` parameter of the parked closure, still suspended inside
/// `handler(connection)` — so nothing releases it, `deinit` never runs, the
/// `for await` in ``AvahiDiscovery/readServerStates(_:)`` never returns, and
/// ``AvahiDiscovery/handleWatchEnding(builtOn:)`` is never reached. Nor does
/// the parked task unwind on its own: `withConnection` awaits
/// `handler(connection)` *beside* the reply loop rather than racing it, and
/// `executeThenClose` runs its body to completion instead of cancelling it when
/// the channel closes.
///
/// So the code below is correct and unreached on that cause. It is kept rather
/// than deleted because it is also what a working detector would call: the
/// generation comparison, the `GetState` convergence and the rebuild are the
/// part that is hard to get right, and none of it depends on which signal woke
/// it up.
///
/// ## What would make it live — a decision not yet taken
///
/// **Not chosen here, and deliberately not built.** The only thing this library
/// lets a connection *holder* observe about a dead transport is a call that
/// fails: there is no close callback, no channel-state stream, and no liveness
/// signal. Since ``SkrepkaIPC/SkrepkaBus/callTimeout`` and
/// ``AvahiDiscovery/probeTimeout`` are now wired through every call, a bus that
/// has gone away surfaces as calls timing out rather than as silence.
/// Invalidating the session on a transport-class failure at the call site —
/// rather than polling, and rather than a liveness probe, which the owner ruled
/// out — is the shape that would reach this file. Which failures count as
/// transport-class, and who invalidates, is a design call nobody has made.
///
/// Comparing ``SkrepkaIPC/BusSession/generation`` at the top of every `call` was
/// the other candidate and is not enough by itself: nothing in `skrepkad` calls
/// avahi on a schedule — after the browse and the publish are up, the next call
/// is a resolve provoked by a browse result, and a dead browse provokes none —
/// so a check that only runs when something calls would notice the reconnect at
/// the moment it can no longer matter. The generation is still what *decides*
/// once something has noticed; see ``AvahiDiscovery/busGeneration``.
///
/// ## Why both causes cannot each spend a rebuild
///
/// A `dbus-daemon` restart usually takes `avahi-daemon` down too, and the new
/// avahi emits `Server.StateChanged(RUNNING)` on its way up. Left alone, a
/// reconnect trigger and the state-changed watch would each rebuild for that
/// one event. They cannot, and the thing that separates them is `GetState`
/// asked at the instant the new subscription is in place:
///
/// - avahi answers `RUNNING` — its `StateChanged` was emitted before this
///   subscription existed, so it can never arrive. This side rebuilds.
/// - avahi answers anything else, or cannot answer — it is still coming up, and
///   the `RUNNING` it will emit lands on a subscription that is now in place.
///   That signal rebuilds; this side does not.
///
/// Exactly one fires, by construction. No debounce window, no timestamp, and
/// nothing that goes wrong if the two are seconds or minutes apart.
extension AvahiDiscovery {
    /// How long to wait before reaching for the bus again after the connection
    /// under the watch went away.
    ///
    /// A restarted `dbus-daemon` is not accepting connections the instant the
    /// old one closed, and retrying with no pause turns that gap into a spin.
    /// Two seconds is also ``probeTimeout``, for the same reason: everything
    /// here is a local socket that answers at once or not at all.
    static let reconnectDelay: Duration = .seconds(2)

    /// How many times in a row a lost bus is worth reaching for.
    ///
    /// Beside ``RecoveryBudget/limit`` and counted the same way — consecutive
    /// failures, reset by one success — so a machine whose bus restarts once a
    /// week recovers every week, and one with no bus at all stops asking.
    static let reconnectAttempts = 5

    /// What a server watch whose signal stream ended should do about it.
    ///
    /// Reachable today only through the resubscribe-on-first-pass path; see the
    /// dormancy note on this file. The decision itself is exercised directly by
    /// `AvahiReconnectTests.swift`, which is the honest extent of the coverage.
    enum WatchEnding: Sendable, Equatable {
        /// The connection is still the one the browser and entry group were
        /// built on, so nothing avahi is holding has gone anywhere. Subscribe
        /// again and carry on.
        ///
        /// The second `AddMatch` that costs is harmless: the bus daemon
        /// reference-counts identical rules, and nothing here ever removes one.
        case resubscribe
        /// The bus was replaced and avahi is already running on the new one.
        /// Everything it was holding is gone, and the `RUNNING` that said so
        /// was emitted before there was anyone to hear it.
        case rebuild
        /// The bus was replaced and avahi is not up on it yet. There is nothing
        /// to rebuild *onto*; the `RUNNING` still to come does it.
        case waitForAvahi
    }

    /// What a watch ending means, given the connection the state was built on,
    /// the connection there is now, and what avahi says about itself.
    ///
    /// Pure and `static` for the reason ``AvahiSignals`` is: it is the part of
    /// the reconnect that can be exercised without a bus. The discussion above
    /// is the argument for the two lines below.
    static func ending(
        builtOn: Int,
        now: Int,
        avahi: AvahiNames.ServerState?
    ) -> WatchEnding {
        guard builtOn != now else { return .resubscribe }
        return avahi == .running ? .rebuild : .waitForAvahi
    }

    /// Watches `Server.StateChanged` for as long as there is a bus to watch it
    /// on, re-subscribing across a connection that goes away.
    ///
    /// One pass per connection: subscribe, note which connection it is, decide
    /// what the *previous* pass ending meant, then read until the stream ends.
    ///
    /// **In practice it makes one pass.** The `for await` in
    /// `readServerStates(_:)` returns only when the subscription finishes, and
    /// with the resolved `dbus` package nothing finishes one while the process
    /// still holds the connection — dead bus included. So the loop is the shape
    /// a reconnect would take rather than a reconnect that happens; the live
    /// work is `readServerStates(_:)` handling an `avahi-daemon` restart on a
    /// session bus that stayed up. See the note on this file.
    func runServerWatch() async {
        var isReconnect = false
        while !Task.isCancelled {
            guard let states = await subscribeToServerState() else { return }
            let built = busGeneration
            busGeneration = await session.generation
            // Never on the first pass. Nothing has been built yet, and the
            // first connection is a change from ``busGeneration``'s zero that
            // would otherwise read as a bus that went away.
            if isReconnect { await handleWatchEnding(builtOn: built) }
            isReconnect = true
            await readServerStates(states)
            guard !Task.isCancelled, await pauseBeforeRetrying() else { return }
        }
    }

    /// Subscribes to `Server.StateChanged` on whatever connection the session
    /// has, waiting out a bus that has not come back yet.
    ///
    /// Nil means the watch is over: the bus did not answer inside
    /// ``reconnectAttempts`` consecutive tries, or the task was cancelled.
    private func subscribeToServerState() async -> AsyncStream<DBusMessage>? {
        var failures = 0
        while !Task.isCancelled {
            do {
                let states = try await signals(
                    interface: AvahiNames.Interface.server,
                    member: AvahiNames.Server.stateChanged
                )
                try await addServerMatch()
                return states
            } catch {
                failures += 1
                guard failures < Self.reconnectAttempts else {
                    // Reported rather than thrown: everything else still works,
                    // and the only thing lost is the restart recovery. A user
                    // who restarts avahi has to restart skrepkad too, and this
                    // line is what tells them so.
                    logger.warning(
                        "cannot watch avahi's own state; a daemon restart will go unnoticed",
                        metadata: ["reason": "\(describe(error))", "attempts": "\(failures)"])
                    return nil
                }
                guard await pauseBeforeRetrying() else { return nil }
            }
        }
        return nil
    }

    /// Waits out ``reconnectDelay``, and says whether the wait finished.
    ///
    /// `false` is cancellation — ``stopEverything()`` — which is the one way
    /// this loop ends that must not be read as a bus that went away.
    private func pauseBeforeRetrying() async -> Bool {
        do {
            try await Task.sleep(for: Self.reconnectDelay)
            return true
        } catch {
            return false
        }
    }

    /// Acts on the pass that just ended, now that the next subscription is in
    /// place and ``busGeneration`` says which connection it is on.
    ///
    /// Not reached today: the pass before it does not end. See the note on this
    /// file for what stops it and what would have to change.
    private func handleWatchEnding(builtOn: Int) async {
        // `GetState` is a bus round trip, and ``ending(builtOn:now:avahi:)``
        // ignores its answer when the generation has not moved. Asking only
        // when it can change the outcome is what keeps a stream that ended for
        // some other reason free.
        guard builtOn != busGeneration else { return }
        let avahi = await avahiServerState()
        switch Self.ending(builtOn: builtOn, now: busGeneration, avahi: avahi) {
        case .resubscribe:
            return
        case .waitForAvahi:
            logger.notice(
                "the bus connection was replaced; waiting for avahi to come back",
                metadata: ["connection": "\(busGeneration)"])
        case .rebuild:
            logger.notice(
                "the bus connection was replaced and avahi is already running; rebuilding",
                metadata: ["connection": "\(busGeneration)"])
            await recover()
        }
    }

    /// What avahi says its own state is, or nil when it cannot say.
    ///
    /// `GetState`, `() -> i`, carrying an `AvahiServerState` — from avahi 0.8's
    /// `org.freedesktop.Avahi.Server.xml`, the same file every other signature
    /// in ``AvahiNames`` is copied from. Asked rather than assumed: a bus
    /// connection that was replaced says nothing about whether avahi was
    /// replaced with it.
    private func avahiServerState() async -> AvahiNames.ServerState? {
        do {
            let reply = try await callServer(AvahiNames.Server.getState)
            guard case .int32(let raw) = reply.first else { return nil }
            return AvahiNames.ServerState(rawValue: raw)
        } catch {
            // Debug rather than a warning, and nil rather than a throw: the
            // ordinary way to reach this is avahi not being back yet, which is
            // an answer the caller acts on rather than a fault.
            logger.debug(
                "avahi did not say what state it is in",
                metadata: ["reason": "\(describe(error))"])
            return nil
        }
    }

    /// Reads one connection's worth of `Server.StateChanged`, and returns when
    /// that connection's subscription finishes.
    private func readServerStates(_ states: AsyncStream<DBusMessage>) async {
        for await message in states {
            guard !Task.isCancelled else { return }
            guard message.path == AvahiNames.serverPath,
                let (state, _) = AvahiSignals.serverState(message.body),
                state == .running
            else { continue }
            // Cheapest checks first: a forged signal that is not even shaped
            // like a `RUNNING` is dropped without asking the bus anything.
            guard await isFromAvahi(message.sender) else { continue }
            await recover()
        }
    }
}
