import DBUS
import Foundation
import Logging
import SkrepkaIPC
import SkrepkaSync

/// Publishing and browsing through `org.freedesktop.Avahi`.
///
/// The Linux half of ``SkrepkaSync/PeerDiscovery``, beside `BonjourDiscovery`
/// on macOS. Talks to avahi over the system bus; it runs no responder of its
/// own and it must not, because co-binding UDP 5353 works for multicast and
/// **only one process receives unicast replies** — an embedded responder
/// running alongside a live `avahi-daemon` breaks discovery for both.
///
/// ## What differs from the Bonjour conformance, and why the protocol allows it
///
/// - **Browse results carry no TXT record.** Avahi's `ItemNew` signal has six
///   arguments and none of them is the record, so every peer arrives as
///   ``SkrepkaSync/DiscoveredPeer/AdvertisementState/unread`` and the record
///   comes from a resolve. `NWBrowser` delivers it inline, which is why that
///   state exists at all.
/// - **Object signals are directed; the server's are broadcast.** avahi-daemon
///   calls `dbus_message_set_destination(m, i->client->name)` on every browser,
///   resolver and entry-group signal — verified against
///   `avahi-daemon/dbus-service-browser.c:168` and `dbus-entry-group.c:84` on
///   the v0.8 tag — so those three need no `AddMatch` rule and none is added.
///   `Server.StateChanged` is the exception: `dbus-protocol.c` emits it with no
///   destination, so it reaches nobody who has not asked `org.freedesktop.DBus`
///   for it. That rule is added, once, in `AvahiDiscovery+Recovery.swift`.
/// - **Subscription happens before the object exists.** The browser avahi
///   creates starts immediately and answers from its cache, so a subscription
///   taken after `ServiceBrowserNew` returns can miss the first results. The
///   library's `subscribeToSignal(interface:member:)` filters on interface and
///   member and not on path, so this subscribes first and filters by object
///   path itself — which closes the race rather than narrowing it.
public actor AvahiDiscovery: PeerDiscovery {
    /// How long any single method call to avahi may take before the daemon is
    /// treated as absent.
    ///
    /// Named for the liveness call to `GetVersionString`, which is the case it
    /// exists for, and applied to every call because every one of them has the
    /// same shape: a request over a Unix socket to a daemon on this machine,
    /// answered immediately or not at all. Two seconds is generous for that; the
    /// point is that a bus which accepts the connection and never answers must
    /// not hang the caller for ever.
    ///
    /// It bounds the *reply*, never the registration behind it — `Commit` is
    /// answered at once and the outcome arrives later as a signal, which is what
    /// ``registrationTimeout`` covers.
    static let probeTimeout: Duration = .seconds(2)

    /// How long avahi gets to say what it did with a committed entry group.
    ///
    /// Beside `BonjourDiscovery.registrationTimeout`, and the same ten seconds:
    /// a `Commit` avahi accepts and never reports on would otherwise hang
    /// ``startAdvertising(_:)`` for ever, because the answer is a signal and a
    /// signal that never comes is indistinguishable from one that is late.
    static let registrationTimeout: Duration = .seconds(10)

    let session: BusSession
    let logger: Logger

    /// The advertisement, once ``startAdvertising(_:)`` has confirmed it.
    var published: ServiceDescriptor?
    var entryGroupPath: String?
    var entryGroupTask: Task<Void, Never>?
    var registrationValue: ServiceRegistration?
    var failureSinks: [UUID: AsyncStream<DiscoveryError>.Continuation] = [:]

    var browserPath: String?
    var browseTasks: [Task<Void, Never>] = []
    var eventSinks: [UUID: AsyncStream<DiscoveryEvent>.Continuation] = [:]
    /// Set once the browse has reported ``SkrepkaSync/DiscoveryEvent/ready``,
    /// so a stream taken later is told the browse is already running rather
    /// than waiting for a `ready` that has been and gone.
    var isBrowseReady = false

    /// Watches `Server.StateChanged`, so an `avahi-daemon` restart is noticed.
    /// Started by the first publish or browse; see
    /// `AvahiDiscovery+Recovery.swift`.
    var serverWatchTask: Task<Void, Never>?
    /// Which watch the current task is. A watch that ends after
    /// ``stopEverything()`` has already forgotten it must not forget the
    /// replacement a later publish started, and comparing generations is how it
    /// tells the two apart.
    var serverWatchGeneration = 0
    /// Rebuilds of the browse since avahi last handed out a browser, and
    /// rebuilds of the advertisement since one was last established.
    ///
    /// **Two budgets rather than one**, because a browser arriving says nothing
    /// about a publish that has not been attempted yet, and the browse is
    /// rebuilt first. See ``RecoveryBudget``.
    var browseRecovery = RecoveryBudget()
    var publishRecovery = RecoveryBudget()

    /// Which of the session's connections the browser and entry group were
    /// built on — ``SkrepkaIPC/BusSession/generation``, sampled when the server
    /// watch subscribed.
    ///
    /// A `dbus-daemon` restart replaces the connection under everything, and
    /// avahi reclaims every object the old connection owned. So a generation
    /// that has moved means the browser is dead and the entry group is gone,
    /// whatever this side still has a path for. Zero until the first watch has
    /// subscribed, which is also `BusSession`'s "nothing has connected yet".
    ///
    /// **Recorded, and not yet compared against anything that fires.** The one
    /// reader is `handleWatchEnding(builtOn:)`, which a bus death does not
    /// currently reach — `AvahiDiscovery+Reconnect.swift` says why, and says
    /// what would have to change. Keeping the sample costs one `await` per
    /// subscription and is what a working detector would need.
    var busGeneration = 0

    /// avahi's unique bus name, as of the last `Server.StateChanged` this
    /// believed. Compared against a signal's sender so a forged one cannot
    /// drive a rebuild; see ``isFromAvahi(_:)``.
    var avahiOwner: String?

    public init(
        session: BusSession = BusSession(bus: .system),
        logger: Logger = Logger(label: "skrepka.avahi")
    ) {
        self.session = session
        self.logger = logger
    }

    public var registration: ServiceRegistration? { registrationValue }

    /// Whether `avahi-daemon` is reachable, and what version it is.
    ///
    /// Called before anything else so "no responder" is reported once, with a
    /// reason, rather than as three separate failures from advertising,
    /// browsing and resolving. `skrepka doctor` reads this.
    public func probe() async -> Result<String, DiscoveryError> {
        do {
            let reply = try await callServer(AvahiNames.Server.versionString)
            guard case .string(let version) = reply.first else {
                return .failure(.responderUnavailable(reason: "avahi answered an unreadable version"))
            }
            return .success(version)
        } catch {
            return .failure(.responderUnavailable(reason: describe(error)))
        }
    }

    /// Stops advertising and browsing, in one call.
    ///
    /// Not a ``SkrepkaSync/PeerDiscovery`` requirement — that protocol has a
    /// stop for each half — but a caller shutting down wants both and should
    /// not have to remember which order they go in.
    ///
    /// **Deliberately does not close the bus connection.** The session is
    /// injected and may be shared: the daemon hands the same one to
    /// ``ClockCheck``, because two connections to a bus get two unique names
    /// and avahi directs every browser and entry-group signal at exactly one of
    /// them. Whoever constructed the ``SkrepkaIPC/BusSession`` closes it.
    public func stopEverything() {
        serverWatchTask?.cancel()
        serverWatchTask = nil
        stopAdvertising()
        stopBrowsing()
    }

    // MARK: - Calling avahi

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
    /// ``probeTimeout`` for everything,
    /// because every call here is a local unary request.
    func call(
        destination: String = AvahiNames.busName,
        path: String,
        interface: String,
        method: String,
        timeout: Duration = AvahiDiscovery.probeTimeout,
        _ arguments: [DBusValue] = []
    ) async throws -> [DBusValue] {
        let connection = try await session.connection()
        let request = DBusRequest.createMethodCall(
            destination: destination,
            path: path,
            interface: interface,
            method: method,
            body: arguments
        )
        let answer: DBusMessage?
        do {
            answer = try await connection.send(
                request, timeoutNanoseconds: timeout.wholeNanoseconds)
        } catch let error as DBusError {
            // `DBusError.timeout` says only "timeout" when it is printed, which
            // in a `skrepka doctor` line is a sentence with no subject.
            if case .timeout = error { throw AvahiError.timedOut(method: method) }
            throw error
        }
        guard let reply = answer else {
            throw AvahiError.noReply(method: method)
        }
        guard reply.messageType != .error else {
            throw AvahiError.refused(method: method, detail: reply.avahiErrorDetail)
        }
        return reply.body
    }

    /// Subscribes to one signal on one interface, before the object that will
    /// emit it exists. See the type's discussion.
    func signals(interface: String, member: String) async throws -> AsyncStream<DBusMessage> {
        let connection = try await session.connection()
        return await connection.subscribeToSignal(interface: interface, member: member)
    }

    /// `Free` on a transient object, ignoring whatever it says.
    ///
    /// Ignored deliberately, and this is the one place in this file a discarded
    /// error is right: the object is being abandoned either way, and avahi
    /// answers `org.freedesktop.Avahi.InvalidObject` for one it has already
    /// destroyed itself — a browse that failed has usually done exactly that.
    /// Reporting it would mean surfacing "the thing you are throwing away was
    /// already thrown away".
    func free(path: String, interface: String, method: String) async {
        _ = try? await call(path: path, interface: interface, method: method)
    }

    func describe(_ error: any Error) -> String {
        if let error = error as? AvahiError { return error.description }
        if let error = error as? BusSession.SessionError { return error.description }
        // A `DiscoveryError` reaches here when one layer's failure is being
        // re-reported by another — a republish that failed becomes an
        // `advertisingLost` — and its own sentence is better than its case name.
        if let error = error as? DiscoveryError { return error.description }
        return String(describing: error)
    }
}

/// Why a call to avahi did not produce an answer.
enum AvahiError: Error, Sendable, CustomStringConvertible {
    case noReply(method: String)
    case refused(method: String, detail: String)
    /// The daemon accepted the call and answered a body this build cannot read.
    case unreadableReply(method: String)
    /// The bus took the call and nothing came back inside
    /// ``AvahiDiscovery/probeTimeout``.
    case timedOut(method: String)

    var description: String {
        switch self {
        case .noReply(let method): "avahi did not answer \(method)"
        case .refused(let method, let detail) where detail.isEmpty: "avahi refused \(method)"
        case .refused(let method, let detail): "avahi refused \(method): \(detail)"
        case .unreadableReply(let method): "avahi answered \(method) with something unreadable"
        case .timedOut(let method): "avahi did not answer \(method) in time"
        }
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
