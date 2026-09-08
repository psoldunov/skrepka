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
    /// watch subscribed and again after every rebuild.
    ///
    /// A `dbus-daemon` restart replaces the connection under everything, and
    /// avahi reclaims every object the old connection owned. So a generation
    /// that has moved means the browser is dead and the entry group is gone,
    /// whatever this side still has a path for. Zero until the first watch has
    /// subscribed, which is also `BusSession`'s "nothing has connected yet".
    ///
    /// Read by `handleWatchEnding(builtOn:)`, which compares it against the
    /// connection a watch pass ended on. Since ``noteTransportLoss(on:)``
    /// brings it up to date as part of the rebuild it drives, a watch pass that
    /// ends because that rebuild replaced the connection sees a generation that
    /// has not moved and correctly declines to rebuild a second time.
    var busGeneration = 0

    /// The rebuild in flight after the connection under this instance went
    /// away, or nil.
    ///
    /// One at a time, which is what stops a rebuild whose own calls fail from
    /// starting another. See `rebuildAfterBusLoss()` in
    /// `AvahiDiscovery+Calls.swift`.
    var busRebuild: Task<Void, Never>?

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
        // A rebuild in flight would otherwise publish a record and start a
        // browse on the way out of a shutdown.
        busRebuild?.cancel()
        busRebuild = nil
        stopAdvertising()
        stopBrowsing()
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
