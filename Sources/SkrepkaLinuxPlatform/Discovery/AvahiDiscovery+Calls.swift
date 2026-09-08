import DBUS
import Foundation
import Logging
// For `BusSession.generation` and `BusSession.invalidate()`. Swift 6's
// MemberImportVisibility needs the module that declares a member imported
// here, not merely somewhere in the target.
import SkrepkaIPC

/// One method call to avahi, and what a call that died says about the bus.
///
/// ## The two ways a call fails, and why they are not the same failure
///
/// **avahi answered no.** An `UnknownMethod`, an `AddService` refused because
/// the record is malformed, an `InvalidObject` for a group avahi already
/// destroyed. The message came back, so the socket underneath it is fine: the
/// daemon is alive and this call was wrong. Nothing about the connection needs
/// touching, and tearing it down would throw away a working browser and a live
/// entry group to punish a typo.
///
/// **Nothing answered.** `send` threw, or the reply did not arrive inside
/// ``AvahiDiscovery/probeTimeout``, or it arrived empty. That is the shape a
/// replaced `dbus-daemon` takes here, because it is the *only* shape it can
/// take: the library exports no close callback, no channel-state stream and no
/// liveness signal, so a call that dies mid-flight is the whole of the evidence
/// a connection holder ever gets. See ``noteTransportLoss(on:)``.
extension AvahiDiscovery {
    func callServer(_ method: String, _ arguments: [DBusValue] = []) async throws -> [DBusValue] {
        try await call(
            path: AvahiNames.serverPath,
            interface: AvahiNames.Interface.server,
            method: method,
            arguments
        )
    }

    /// One method call, bounded.
    ///
    /// `destination` is avahi for everything but the `AddMatch` and the
    /// `GetNameOwner` that have to go to the bus daemon; `timeout` is
    /// ``AvahiDiscovery/probeTimeout`` for everything, because every call here
    /// is a local unary request.
    func call(
        destination: String = AvahiNames.busName,
        path: String,
        interface: String,
        method: String,
        timeout: Duration = AvahiDiscovery.probeTimeout,
        _ arguments: [DBusValue] = []
    ) async throws -> [DBusValue] {
        let connection = try await session.connection()
        // Sampled after the connection is in hand rather than before, because
        // before the first open the generation is still zero and would never
        // match. See ``noteTransportLoss(on:)`` for what it is compared to.
        let builtOn = await session.generation
        let request = DBusRequest.createMethodCall(
            destination: destination,
            path: path,
            interface: interface,
            method: method,
            body: arguments
        )
        let reply = try await answer(
            to: request, on: connection, method: method, timeout: timeout, builtOn: builtOn)
        // Deliberately outside ``answer(to:on:method:timeout:builtOn:)``: an
        // error reply is avahi speaking, so it must not be reported as the
        // transport dying.
        guard reply.messageType != .error else {
            throw AvahiError.refused(method: method, detail: reply.avahiErrorDetail)
        }
        return reply.body
    }

    /// The reply to one request, or a throw that has already been reported as a
    /// transport loss.
    private func answer(
        to request: DBusRequest,
        on connection: DBusClient.Connection,
        method: String,
        timeout: Duration,
        builtOn: Int
    ) async throws -> DBusMessage {
        do {
            let received = try await connection.send(
                request, timeoutNanoseconds: timeout.wholeNanoseconds)
            // A nil answer is the third transport-shaped failure, beside a
            // throw and a timeout: the send completed and nothing came back.
            guard let reply = received else { throw AvahiError.noReply(method: method) }
            return reply
        } catch {
            // A call that ended because this task was cancelled says nothing
            // about the bus — ``stopEverything()`` is the ordinary way to get
            // here — and invalidating on it would drop a live connection that
            // ``ClockCheck`` and the rest of the daemon share.
            if !Task.isCancelled { await noteTransportLoss(on: builtOn) }
            // `DBusError.timeout` says only "timeout" when it is printed, which
            // in a `skrepka doctor` line is a sentence with no subject.
            if let error = error as? DBusError, case .timeout = error {
                throw AvahiError.timedOut(method: method)
            }
            throw error
        }
    }

    // MARK: - A call that died

    /// Acts on a call that failed in a way that says the connection under it is
    /// gone, by dropping that connection and rebuilding onto its replacement.
    ///
    /// **The accepted trade.** There is no liveness probe here, and the owner
    /// ruled one out, so "the bus was replaced" and "avahi is alive and slower
    /// than ``AvahiDiscovery/probeTimeout``" are the same observation at this
    /// point and both reconnect. A genuinely slow-but-alive avahi therefore
    /// costs a reconnect and a rebuild of the browse and the advertisement.
    /// That is self-healing and cheap — one connect, one `ServiceBrowserNew`,
    /// one entry group — and the alternative is a second round trip on a bus
    /// that may well not be answering either.
    ///
    /// - Parameter builtOn: ``SkrepkaIPC/BusSession/generation`` as it was when
    ///   this call went out. A caller whose connection has already been replaced
    ///   is reporting a death somebody else has already dealt with, and
    ///   invalidating on that would throw away the *live* connection instead.
    ///   That also makes this idempotent across the several concurrent calls a
    ///   single dead bus fails all at once: the first one through invalidates,
    ///   which moves the generation, and the rest fall out here.
    func noteTransportLoss(on builtOn: Int) async {
        guard await session.generation == builtOn else { return }
        await session.invalidate()
        rebuildAfterBusLoss()
    }

    /// Rebuilds what avahi was holding, once, off the failing call's own stack.
    ///
    /// Unstructured and guarded rather than awaited inline, for two reasons.
    /// The rebuild makes bus calls of its own, and one of those failing against
    /// a bus that is still down re-enters ``noteTransportLoss(on:)`` — the task
    /// this guard holds is what makes that a no-op rather than a recursion. And
    /// the call that noticed has an error to return to its own caller; making
    /// it wait out a publish first turns one dead call into a ten-second one.
    ///
    /// **``recover()`` and nothing else.** It is the single rebuild path, and
    /// the budgets it spends from are what stop a bus that never comes back
    /// being retried for ever.
    private func rebuildAfterBusLoss() {
        // Nothing built is nothing to rebuild. `skrepka doctor` constructs an
        // instance, calls ``probe()`` and exits; a probe that times out against
        // a machine with no bus must not start a recovery loop.
        guard published != nil || browserPath != nil || !browseTasks.isEmpty else { return }
        guard busRebuild == nil else { return }
        logger.notice("the bus connection under avahi went away; rebuilding on a new one")
        busRebuild = Task { [weak self] in
            await self?.recoverOntoNewConnection()
            await self?.clearBusRebuild()
        }
    }

    private func recoverOntoNewConnection() async {
        await recover()
        // Which connection the browse and the entry group are now built on,
        // sampled after the rebuild because it is the rebuild's own calls that
        // opened the replacement. It is also what keeps this from costing two
        // rebuilds if the server watch's stream ends on the connection that
        // died: ``ending(builtOn:now:avahi:)`` sees a generation that has not
        // moved since and answers `.resubscribe`.
        busGeneration = await session.generation
    }

    private func clearBusRebuild() {
        busRebuild = nil
    }

    // MARK: - Signals, and giving objects back

    /// Subscribes to one signal on one interface, before the object that will
    /// emit it exists. See ``AvahiDiscovery``'s own discussion.
    func signals(interface: String, member: String) async throws -> AsyncStream<DBusMessage> {
        let connection = try await session.connection()
        return await connection.subscribeToSignal(interface: interface, member: member)
    }

    /// `Free` on a transient object, ignoring whatever it says.
    ///
    /// Ignored deliberately, and this is the one place in this backend a
    /// discarded error is right: the object is being abandoned either way, and
    /// avahi answers `org.freedesktop.Avahi.InvalidObject` for one it has
    /// already destroyed itself — a browse that failed has usually done exactly
    /// that. Reporting it would mean surfacing "the thing you are throwing away
    /// was already thrown away".
    func free(path: String, interface: String, method: String) async {
        _ = try? await call(path: path, interface: interface, method: method)
    }
}

extension Duration {
    /// Whole nanoseconds, for `DBusClient.Connection.send(_:timeoutNanoseconds:)`
    /// — which takes a `UInt64` rather than a `Duration`.
    ///
    /// Saturating rather than trapping at both ends: a negative deadline is a
    /// deadline that has passed, and one longer than 584 years is one nothing is
    /// waiting for. Neither is worth crashing a daemon over.
    var wholeNanoseconds: UInt64 {
        let parts = components
        guard parts.seconds > 0 || parts.attoseconds > 0 else { return 0 }
        let seconds = UInt64(clamping: parts.seconds)
        let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflowed else { return .max }
        let (total, wrapped) = scaled.addingReportingOverflow(
            UInt64(clamping: parts.attoseconds) / 1_000_000_000)
        return wrapped ? .max : total
    }
}

extension DBusMessage {
    /// The human half of an error reply, which D-Bus convention puts first in
    /// the body.
    var avahiErrorDetail: String {
        guard case .string(let detail) = body.first else { return "" }
        return detail
    }
}
