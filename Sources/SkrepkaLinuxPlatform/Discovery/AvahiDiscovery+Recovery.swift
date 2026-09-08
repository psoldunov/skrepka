import DBUS
import Foundation
import Logging
import SkrepkaSync

/// Surviving an `avahi-daemon` restart.
///
/// A restart destroys every `EntryGroup` and `ServiceBrowser` the daemon was
/// holding, and **nothing is signalled about it**: the objects that would have
/// emitted `StateChanged` or `Failure` died with the daemon that emitted them.
/// So an advertisement and a browse both go quiet, indefinitely, and no error
/// arrives anywhere. `systemctl restart avahi-daemon` or an ordinary package
/// upgrade is enough to reach that state.
///
/// The one thing that does arrive is `Server.StateChanged`, which the new daemon
/// emits on its way to `AVAHI_SERVER_RUNNING`. That is the cue to build the two
/// objects again from scratch.
///
/// **`Server.StateChanged` needs a match rule and the object signals do not.**
/// avahi directs browser, resolver and entry-group signals at one client with
/// `dbus_message_set_destination`; `dbus-protocol.c` broadcasts the server's own
/// with no destination, and a broadcast reaches only clients that asked
/// `org.freedesktop.DBus` for it. Without the `AddMatch` below the subscription
/// is silently deaf — which looks exactly like a daemon that never restarted.
///
/// The rule is not a filter, though, only a subscription: a *directed* signal is
/// delivered whatever the rules say, so what actually decides that a
/// `StateChanged` came from avahi is ``AvahiDiscovery/isFromAvahi(_:)``.
extension AvahiDiscovery {
    /// Starts the watch, once, on the first publish or browse.
    ///
    /// Not started in `init`, because a `AvahiDiscovery` that is constructed and
    /// never used should not open a bus connection — `skrepka doctor`
    /// constructs one to call ``probe()`` and nothing else.
    func ensureServerWatch() {
        guard serverWatchTask == nil else { return }
        serverWatchGeneration += 1
        let generation = serverWatchGeneration
        serverWatchTask = Task { [weak self] in
            await self?.runServerWatch()
            await self?.clearServerWatch(generation)
        }
    }

    /// Forgets the watch, so a later publish or browse can start another — but
    /// only if it is still this one. See ``serverWatchGeneration``.
    func clearServerWatch(_ generation: Int) {
        guard generation == serverWatchGeneration else { return }
        serverWatchTask = nil
    }

    /// Notes that avahi handed out a working browser.
    ///
    /// Refills the browse budget and **only** the browse budget: an advertisement
    /// is rebuilt after the browse and has not been attempted yet at this point,
    /// so letting this refill both is what stopped ``RecoveryBudget/limit`` ever
    /// engaging.
    func recordBrowseWorking() {
        browseRecovery.recordWorking()
    }

    /// Notes that avahi established the advertisement, which is the last thing
    /// that happens in a publish and so the one place it has genuinely worked
    /// end to end.
    func recordAdvertisementWorking() {
        publishRecovery.recordWorking()
    }

    /// Whether a `Server.StateChanged` really came from `avahi-daemon`.
    ///
    /// The `AddMatch` rule above filters **broadcasts**, and the D-Bus
    /// specification is explicit that "messages that list a client as their
    /// `DESTINATION` do not need to match the client's match rules, and are sent
    /// to that client regardless". The default system-bus policy permits
    /// `send_type="signal"`, so without this check any process on the machine
    /// could aim a directed `StateChanged` at this client's unique name and
    /// drive a rebuild of the browse and the advertisement on demand. Nothing
    /// here grants anything on the strength of the signal, so that is denial of
    /// service rather than a trust hole — and one comparison closes it.
    ///
    /// What arrives in `sender` is the **unique** name of the sending
    /// connection, `:1.42` and never the well-known `org.freedesktop.Avahi`:
    /// the spec has the bus daemon control that field, which is what makes it
    /// "as reliable and trustworthy as the message bus itself" and what makes a
    /// literal comparison against the well-known name reject every real signal.
    ///
    /// Resolved on demand rather than tracked through `NameOwnerChanged`,
    /// deliberately. The unique name changes on every restart — precisely the
    /// event this watch exists for — and two independent signal streams give no
    /// ordering between the rename and the state change, so a `NameOwnerChanged`
    /// processed late would reject the real `RUNNING` and leave recovery dead
    /// for good. The answer is cached instead, which costs one round trip per
    /// restart rather than one per signal; a cached unique name cannot be
    /// impersonated later, because `dbus-daemon` never reissues one.
    func isFromAvahi(_ sender: String?) async -> Bool {
        guard let sender else { return false }
        if sender == avahiOwner { return true }
        guard let owner = await avahiNameOwner() else { return false }
        avahiOwner = owner
        return sender == owner
    }

    /// Which connection owns `org.freedesktop.Avahi` right now, or `nil`.
    ///
    /// `STRING GetNameOwner (in STRING name)`, from the D-Bus specification's
    /// `org.freedesktop.DBus` interface, which answers
    /// `org.freedesktop.DBus.Error.NameHasNoOwner` when nothing owns the name.
    private func avahiNameOwner() async -> String? {
        do {
            let reply = try await call(
                destination: AvahiNames.BusDaemon.name,
                path: AvahiNames.BusDaemon.path,
                interface: AvahiNames.BusDaemon.interface,
                method: AvahiNames.BusDaemon.getNameOwner,
                [.string(AvahiNames.busName)]
            )
            guard case .string(let owner) = reply.first, !owner.isEmpty else { return nil }
            return owner
        } catch {
            // Debug rather than a warning: the ordinary way to reach this is a
            // signal from someone who is not avahi, which is exactly the case
            // being refused, and logging that at notice would hand the sender a
            // way to fill the journal.
            logger.debug(
                "cannot tell who owns avahi's bus name; ignoring the state it reported",
                metadata: ["reason": "\(describe(error))"])
            return nil
        }
    }

    /// Subscribes this connection to avahi's broadcast server signals.
    ///
    /// One of the two calls in this backend that go to the bus daemon rather
    /// than to avahi; ``avahiNameOwner()`` is the other.
    ///
    /// The reply is checked, because `AddMatch` reports a malformed or
    /// over-quota rule as an error *reply* rather than by failing to send — and
    /// a discarded reply here would leave the watch below running and deaf.
    /// ``call(destination:path:interface:method:timeout:_:)`` throws on an error
    /// reply, which is what makes checking it one line rather than five.
    func addServerMatch() async throws {
        _ = try await call(
            destination: AvahiNames.BusDaemon.name,
            path: AvahiNames.BusDaemon.path,
            interface: AvahiNames.BusDaemon.interface,
            method: AvahiNames.BusDaemon.addMatch,
            [.string(AvahiNames.BusDaemon.serverStateRule)]
        )
    }

    /// Rebuilds whatever this instance had up before the daemon went away.
    ///
    /// Each half spends from its own budget, so the browse — which is rebuilt
    /// first and reports success first — cannot hand the advertisement a fresh
    /// budget it did nothing to earn.
    ///
    /// **The single rebuild path, and deliberately the only one.** Both things
    /// that destroy avahi's objects are routed here: the daemon restarting,
    /// which arrives as `Server.StateChanged` and is the case that works today,
    /// and the *bus* restarting, which has nothing that notices it yet.
    /// `AvahiDiscovery+Reconnect.swift` holds the second route — why it is
    /// dormant, what would make it fire, and how the two are kept from each
    /// spending a rebuild for one event once it does.
    func recover() async {
        let descriptor = published
        let wasBrowsing = browserPath != nil || !browseTasks.isEmpty
        guard descriptor != nil || wasBrowsing else { return }
        if wasBrowsing, spendBrowseAttempt() {
            restartBrowse()
        }
        if let descriptor, spendPublishAttempt() {
            await republish(descriptor)
        }
    }

    private func spendBrowseAttempt() -> Bool {
        let spent = browseRecovery.spend()
        report(spent, attempts: browseRecovery.attempts, on: "the browse")
        return spent
    }

    private func spendPublishAttempt() -> Bool {
        let spent = publishRecovery.spend()
        report(spent, attempts: publishRecovery.attempts, on: "the advertisement")
        return spent
    }

    /// Says what one half is about to do, or why it is not going to.
    private func report(_ spent: Bool, attempts: Int, on half: String) {
        guard spent else {
            logger.warning(
                "avahi restarted again and the last rebuilds did not hold; leaving this alone",
                metadata: ["part": "\(half)", "attempts": "\(attempts)"])
            return
        }
        logger.notice(
            "avahi is running again; rebuilding what it was holding",
            metadata: ["part": "\(half)", "attempt": "\(attempts)"])
    }

    /// Starts a **new** browse on the streams the old one was feeding.
    ///
    /// Deliberately not ``stopBrowsing()``: that finishes every stream
    /// ``startBrowsing()`` handed out, and a finished stream is the contract for
    /// a browse that is over. A restart is not over, so the sinks are kept and
    /// the new browse announces itself down them with a second `ready` — the
    /// same event a caller already handles, and the reason `ready` is not
    /// once-only.
    ///
    /// The dead browser is not `Free`d. The object went with the daemon, so the
    /// call would reach a new daemon that never heard of that path and be
    /// refused; dropping the path is the whole of the teardown.
    private func restartBrowse() {
        for task in browseTasks { task.cancel() }
        browseTasks = []
        browserPath = nil
        isBrowseReady = false
        startBrowse()
    }

    /// Publishes again under a fresh entry group, keeping the failure sinks.
    ///
    /// Same reasoning as the browse: ``stopAdvertising()`` finishes the streams
    /// ``advertisementFailures()`` handed out, and a caller whose stream ends is
    /// entitled to conclude the advertisement is gone for good.
    private func republish(_ descriptor: ServiceDescriptor) async {
        entryGroupTask?.cancel()
        entryGroupTask = nil
        entryGroupPath = nil
        published = nil
        registrationValue = nil
        do {
            try await publish(descriptor)
        } catch {
            // Now it is a genuine loss: the record is gone and this side could
            // not put it back. `reportLoss` finishes the failure streams, which
            // is the honest end state.
            reportLoss(.advertisingLost(reason: describe(error)))
        }
    }
}
