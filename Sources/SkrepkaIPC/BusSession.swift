import DBUS
import Foundation
import Logging

/// A D-Bus connection that outlives the call that opened it.
///
/// ## Why this type exists
///
/// `DBusClient`'s connection API is scoped — `withSystemBus { connection in … }`
/// — and tears the connection down when the closure returns. That is the right
/// shape for a CLI, which makes one call and exits, and the wrong shape for
/// everything else here: `AvahiDiscovery` publishes a record and browses for
/// minutes or days, and the daemon owns a bus name for as long as it runs.
///
/// So the closure is parked rather than escaped. A `Task` enters it, hands the
/// connection out, and then waits on a stream that nothing ever yields to;
/// ``stop()`` *finishes* that stream, the wait ends, the closure returns and
/// the library performs its own teardown. Nothing reaches around the library's
/// lifetime management, which is what makes this safe rather than clever.
///
/// ## Why readiness is a stream and not a continuation
///
/// The obvious version stores a `CheckedContinuation` on this actor and resumes
/// it from the task. That is the shape with a `SWIFT TASK CONTINUATION MISUSE`
/// in it — resumed twice if the task both connects and then fails, dropped
/// entirely if the task is cancelled between the two — and the failure is a
/// process that hangs rather than one that reports. A one-element
/// `AsyncStream` cannot be double-resumed and cannot be dropped: a stream that
/// finishes without yielding ends the `for await` and the reader sees nothing,
/// which is a state with a name rather than a hang.
///
/// ## Why the in-flight connect is itself stored
///
/// Being an actor is not enough. ``connection()`` suspends while the bus
/// handshake happens, and a second caller entering during that suspension would
/// see no connection yet and open a second one — two unique names, and a signal
/// directed at one never reaching the other. The half-built state of the first
/// attempt would also be overwritten, leaving a task parked for the life of the
/// process on a stream nothing can finish. So the *attempt* is stored, not just
/// its result, and a second caller awaits the same `Task`.
public actor BusSession {
    /// Which bus to open.
    public enum Bus: Sendable {
        /// `org.freedesktop.Avahi` lives here.
        case system
        /// Where `dev.soldunov.Skrepka` is exported, and where the desktop's
        /// own services live.
        case session
    }

    /// What the parked task reports back, once.
    ///
    /// The failure is a `String` rather than an `any Error` because `Error` is
    /// not `Sendable` and this crosses a task boundary. Nothing is lost: every
    /// caller turns it into a `reason:` string anyway.
    private enum Outcome: Sendable {
        case connected(DBusClient.Connection)
        case failed(String)
    }

    /// Why a session could not be opened.
    public enum SessionError: Error, Sendable, CustomStringConvertible {
        /// The bus refused the connection, or there was no bus to connect to.
        case cannotConnect(reason: String)
        /// The task ended without reporting either way.
        ///
        /// Reached when ``BusSession/stop()`` finishes the readiness stream
        /// while a connect is still in flight — not by cancelling the task that
        /// is awaiting `connection()`. Awaiting a `Task`'s value neither throws
        /// on the awaiting task's own cancellation nor cancels the awaited
        /// task, so a caller that cancels stays suspended until the handshake
        /// finishes either way. Reword this if that is ever made cancellable.
        case cancelled

        public var description: String {
            switch self {
            case .cannotConnect(let reason): "cannot connect to the bus: \(reason)"
            case .cancelled: "connecting to the bus was cancelled"
            }
        }
    }

    private let bus: Bus
    private let address: String?
    private let logger: Logger

    /// The parked task, holding the library's connection closure open.
    private var task: Task<Void, Never>?
    /// The connect attempt — in flight or finished. A second ``connection()``
    /// awaits this rather than starting its own.
    private var connecting: Task<DBusClient.Connection, any Error>?
    /// Finishing this is what un-parks the task and closes the connection.
    private var parking: AsyncStream<Void>.Continuation?
    /// Bumped by every attempt and by every ``stop()``, so a caller suspended
    /// across one can tell whether the state it is about to unwind is still its
    /// own. Cheaper and more obvious than comparing task identities. Not
    /// ``generation``: this counts state transitions, including the failures
    /// and teardowns a caller has no use for.
    private var epoch = 0

    /// How many underlying connections this session has opened.
    ///
    /// Zero before the first, and up by exactly one per connection opened; a
    /// failed attempt does not move it. Anything a caller builds *on the bus* —
    /// a browser, an entry group, a well-known name — belongs to one underlying
    /// connection and dies with it, so a caller records the value it built that
    /// state under and compares later. A different value means the server side
    /// of all of it was reclaimed and has to be rebuilt, not reused.
    public private(set) var generation = 0

    /// - Parameters:
    ///   - bus: Which well-known bus to open, when no `address` is given.
    ///   - address: An explicit bus to connect to instead of the well-known
    ///     one, either a D-Bus address (`unix:path=/run/user/1000/bus`) or a
    ///     bare socket path (`/run/user/1000/bus`), which is read as
    ///     `unix:path=`. Nil — the default — means the well-known `bus`. This
    ///     exists so a test can point at a socket that cannot exist and get a
    ///     deterministic connect failure on a machine that does have a bus.
    public init(bus: Bus, address: String? = nil, logger: Logger = Logger(label: "skrepka.bus")) {
        self.bus = bus
        self.address = address
        self.logger = logger
    }

    /// The live connection, opening one if this is the first call.
    ///
    /// Idempotent: a second call returns the connection the first opened, and a
    /// second call made *while* the first is still connecting awaits that same
    /// attempt. That matters because the daemon reaches for the session bus
    /// from several places and one process should hold one connection to a bus
    /// — two would each get their own unique name, and a signal directed at one
    /// would not reach the other.
    ///
    /// The guarantee is *fresh at fetch*, not fresh for the lifetime of the
    /// value returned. A connection this session has seen end is dropped, so
    /// the next call opens a new one — but a `DBusClient.Connection` fetched
    /// before that is still the dead one, and this session has no way to reach
    /// into a value a caller already holds. That window is accepted rather than
    /// closed: every caller here fetches the connection per call, so it spans
    /// one in-flight call, which fails and is retried against the replacement.
    /// Do not stash the returned value in a property — that is what would turn
    /// a one-call window into a permanent one. Compare ``generation`` instead
    /// when state built on the bus has to outlive a call.
    ///
    /// What this session can see a connection end *from* is narrower than it
    /// should be — see the note in ``beginConnecting(epoch:)``.
    public func connection() async throws -> DBusClient.Connection {
        if let connecting { return try await connecting.value }

        epoch += 1
        let attempt = epoch
        let opening = beginConnecting(epoch: attempt)
        connecting = opening
        do {
            return try await opening.value
        } catch {
            // Unwind the failed attempt so the next caller opens a fresh one
            // rather than awaiting a task that can only rethrow — unless
            // somebody else has already moved on, which the epoch says.
            if epoch == attempt { await stop() }
            throw error
        }
    }

    /// Closes the connection and lets the parked task unwind. Idempotent.
    public func stop() async {
        epoch += 1
        connecting?.cancel()
        connecting = nil
        parking?.finish()
        parking = nil
        // Cleared before the await: a caller entering ``connection()`` during
        // it installs a fresh task, and this must not then nil that one out.
        let parked = task
        task = nil
        // Awaited rather than cancelled: cancelling the task would unwind it
        // through the library's own teardown from the wrong side, and the
        // finish above is what it is waiting for.
        await parked?.value
    }

    /// Starts the parked task and returns the attempt that resolves to its
    /// connection. Both stored properties are assigned before this returns, so
    /// there is no suspension point for a second caller to slip through.
    ///
    /// - Parameter epoch: The ``epoch`` this attempt belongs to, carried back
    ///   so what the task writes can be discarded once the state it was started
    ///   for is no longer the state on the actor.
    private func beginConnecting(epoch attempt: Int) -> Task<DBusClient.Connection, any Error> {
        let (ready, readySink) = AsyncStream<Outcome>.makeStream()
        let (parked, parkingSink) = AsyncStream<Void>.makeStream()
        parking = parkingSink

        let bus = bus
        let address = address
        let logger = logger
        // Weak: this task parks for as long as the connection lives, and a
        // strong capture would keep alive a session nothing can ``stop()``.
        task = Task { [weak self] in
            do {
                try await Self.open(bus, address: address, logger: logger) { connection in
                    readySink.yield(.connected(connection))
                    readySink.finish()
                    // Nothing ever yields to `parked`. `stop()` finishes it,
                    // which ends this loop and returns from the closure, which
                    // is where the library closes the channel.
                    for await _ in parked { break }
                }
            } catch {
                readySink.yield(.failed(String(describing: error)))
                readySink.finish()
            }
            // Reached when the library's connection closure unwinds — the drop
            // signal the transport gives for free, no probe and no heartbeat.
            // It fires for a ``stop()`` and for a handshake that never
            // completed. It does *not* fire for a channel that dies under a
            // live connection, which is a limit of the DBUS in
            // `Package.resolved`, not of this design: `withConnection` awaits
            // `handler(connection)` beside its reply loop rather than racing it
            // (`DBusClient.swift:398-431`) and `executeThenClose` runs a body
            // to completion rather than cancelling it on close, so nothing
            // finishes `parked`. Closing that needs a signal the library does
            // not export, or a caller reporting a call that died mid-flight.
            await self?.parkedTaskEnded(epoch: attempt)
        }

        return Task { [weak self] in
            for await outcome in ready {
                switch outcome {
                case .connected(let opened):
                    // Counted here rather than in ``connection()`` so it is
                    // counted once per open and before any caller can read it:
                    // every caller of this attempt awaits this one task.
                    await self?.countOpened()
                    return opened
                case .failed(let reason): throw SessionError.cannotConnect(reason: reason)
                }
            }
            throw SessionError.cancelled
        }
    }

    /// One more underlying connection has been opened.
    private func countOpened() {
        generation += 1
    }

    /// The parked task has unwound, so the connection it was holding open is
    /// gone. Drop it, so the next ``connection()`` opens a fresh one instead of
    /// handing back a corpse.
    ///
    /// - Parameter attempt: The ``epoch`` the ended task was started under. A
    ///   mismatch means ``stop()`` — or a later attempt — has already torn this
    ///   state down and may have replaced it, so clearing would nil out
    ///   somebody else's live task. It is also what keeps a ``stop()`` unwind
    ///   out of the teardown already in flight: ``stop()`` bumps the epoch
    ///   before it finishes the parking stream, so its unwind always mismatches.
    private func parkedTaskEnded(epoch attempt: Int) {
        guard epoch == attempt else { return }
        connecting = nil
        parking = nil
        task = nil
    }

    private static func open(
        _ bus: Bus,
        address: String?,
        logger: Logger,
        _ body: @Sendable @escaping (DBusClient.Connection) async throws -> Void
    ) async throws {
        let auth = SkrepkaBus.authentication()
        if let address {
            let explicit = try parse(address)
            try await DBusClient.withConnection(to: explicit, auth: auth, logger: logger, body)
            return
        }
        switch bus {
        case .system:
            try await DBusClient.withSystemBus(auth: auth, logger: logger, body)
        case .session:
            try await DBusClient.withSessionBus(auth: auth, logger: logger, body)
        }
    }

    /// A bare path is the spelling everyone reaches for first, and
    /// `DBusAddress.parse` rejects it — so accept both rather than making the
    /// difference a caller's problem.
    private static func parse(_ address: String) throws -> DBusAddress {
        if address.hasPrefix("/") { return .unix(path: address) }
        return try DBusAddress.parse(address)
    }
}
