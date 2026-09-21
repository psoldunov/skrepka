import Foundation
import Logging
import NIOCore
import NIOPosix
import SkrepkaSync

/// skrepkad's own mDNS responder, for a system whose avahi refuses to publish.
///
/// SteamOS ships `/etc/avahi/avahi-daemon.conf` with `disable-publishing=yes`
/// and `disable-user-service-publishing=yes`, so avahi browses and resolves
/// but will not publish anything — not a service, not even the machine's own
/// address. Changing that needs root and does not survive an OS update. This
/// publishes the one service skrepkad needs without either: it answers for
/// `_skrepka._tcp` and for a host name of its own, beside an avahi that keeps
/// doing the browsing (see ``MDNSSocket`` for how the two share UDP 5353).
///
/// **Used only when avahi says no.** `AvahiDiscovery` publishes through avahi
/// first and falls back here on `NotPermitted`; a system whose avahi publishes
/// never opens a socket of its own.
///
/// What it does, by RFC 6762 section: probes the two names it claims (§8.1,
/// without §8.2's tiebreak — see ``MDNSConflict``), announces three times at
/// one and two seconds (§8.3), answers QM, QU and legacy unicast queries with
/// known-answer suppression (§5.4, §6, §6.7, §7.1), re-announces when the TXT
/// record changes (§8.4), renames on a conflict (§9) and says goodbye on stop
/// (§10.1). Not implemented: §7.2 multipacket known-answer lists, §7.3/§7.4
/// duplicate suppression, §6.4 aggregation, and IPv6 (see ``MDNSInterface``).
actor MDNSAnnouncer {
    enum Phase: Sendable {
        case idle
        case probing
        case established
    }

    /// How many names one start is worth trying — the same bound
    /// `AvahiDiscovery.nameAttempts` sets for avahi's renames, doubled because
    /// a probe here is also the only way to find out.
    static let nameAttempts = 8
    /// How often the interface list is read again. A Steam Deck joining Wi-Fi
    /// after skrepkad started is the case this is for.
    static let interfacePollInterval: Duration = .seconds(10)
    /// RFC 6762 §5.4: answer a QU question by unicast only if the records went
    /// out by multicast within a quarter of their TTL — the host records'
    /// 120 seconds, the shortest.
    static let recentMulticastWindow: Duration = .seconds(30)

    let logger: Logger
    let eventLoops: any EventLoopGroup

    var phase = Phase.idle
    var descriptor: ServiceDescriptor?
    /// ``descriptor``'s TXT record in wire form, built when the descriptor
    /// arrives so a malformed one is refused there rather than at every answer.
    var txt: [UInt8] = []
    /// Which name the probe is on; 1 is the unadorned one. See ``MDNSNaming``.
    var attempt = 1
    /// Whether the probe round in flight has heard a defence. See
    /// ``MDNSProbeWindow``.
    var probeWindow = MDNSProbeWindow.closed
    /// Bumped by every start and stop, so a task begun under one run can tell
    /// it has been superseded when it resumes.
    var generation = 0
    /// The re-probe a §9 conflict started. Tracked so a stop or a restart
    /// cancels it rather than letting it announce after the goodbye.
    var reprobe: Task<Void, Never>?
    /// Probe-then-announce rounds for links that appeared after the start.
    var linkRounds: [Int: Task<Void, Never>] = [:]
    /// Reports the responder giving up — every alternative name taken after a
    /// conflict. The one consumer is `AvahiDiscovery`, which turns it into an
    /// `advertisingLost`.
    let losses: AsyncStream<MDNSAnnouncerError>
    let lossSink: AsyncStream<MDNSAnnouncerError>.Continuation
    var sockets: [Int: MDNSSocket] = [:]
    var readers: [Int: Task<Void, Never>] = [:]
    var lastMulticast: [Int: ContinuousClock.Instant] = [:]
    var interfaceWatch: Task<Void, Never>?
    var announcing: Task<Void, Never>?

    init(
        logger: Logger = Logger(label: "skrepka.mdns"),
        eventLoops: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.logger = logger
        self.eventLoops = eventLoops
        (losses, lossSink) = AsyncStream<MDNSAnnouncerError>.makeStream()
    }

    /// The name and port being answered for, once the probe has settled.
    var registration: ServiceRegistration? {
        guard phase == .established, let descriptor else { return nil }
        return ServiceRegistration(
            name: instanceLabel(for: descriptor),
            serviceType: ServiceDescriptor.serviceType,
            domain: "local",
            port: descriptor.port
        )
    }

    /// Opens the sockets, claims the names and announces them.
    ///
    /// Returns once announcing has begun. Throws when the port cannot be
    /// shared or every name was taken; a machine with no network yet is not
    /// an error — the interface watch announces when one appears.
    func start(_ descriptor: ServiceDescriptor) async throws -> ServiceRegistration {
        await stop()
        txt = try Self.wireRecord(descriptor)
        self.descriptor = descriptor
        attempt = 1
        try await openSockets()
        startInterfaceWatch()
        try await claimNames()
        announceEverywhere()
        guard let registration else { throw MDNSAnnouncerError.notEstablished }
        return registration
    }

    /// Takes a changed record. A TXT-only change — the pairing window opening
    /// or closing — is re-announced in place (§8.4); a new display name is a
    /// new instance name and goes through probing again.
    func update(_ descriptor: ServiceDescriptor) async throws -> ServiceRegistration {
        guard let current = self.descriptor, phase == .established,
            current.displayName == descriptor.displayName
        else { return try await start(descriptor) }
        txt = try Self.wireRecord(descriptor)
        self.descriptor = descriptor
        announceEverywhere()
        guard let registration else { throw MDNSAnnouncerError.notEstablished }
        return registration
    }

    /// Says goodbye (§10.1) and closes every socket. Idempotent.
    func stop() async {
        generation += 1
        interfaceWatch?.cancel()
        interfaceWatch = nil
        announcing?.cancel()
        announcing = nil
        reprobe?.cancel()
        reprobe = nil
        for round in linkRounds.values { round.cancel() }
        linkRounds = [:]
        if phase == .established { await sendEverywhere { $0.goodbye() } }
        phase = .idle
        for reader in readers.values { reader.cancel() }
        readers = [:]
        for socket in sockets.values { await socket.close() }
        sockets = [:]
        lastMulticast = [:]
    }

    // MARK: - Records

    func instanceLabel(for descriptor: ServiceDescriptor) -> String {
        MDNSNaming.instanceLabel(for: descriptor, attempt: attempt)
    }

    /// The records for one interface, or — `interface` nil — with every
    /// address this host holds, which is what conflict detection compares
    /// against.
    func records(on interface: MDNSInterface?) -> MDNSServiceRecords? {
        guard let descriptor else { return nil }
        let addresses = interface?.addresses ?? sockets.values.flatMap(\.interface.addresses)
        return MDNSServiceRecords(
            instanceLabel: instanceLabel(for: descriptor),
            hostLabel: MDNSNaming.hostLabel(for: descriptor.deviceID, attempt: attempt),
            port: descriptor.port,
            txt: txt,
            addresses: addresses)
    }

    /// Takes on names a probe already settled, without opening a socket.
    ///
    /// The seam the conflict and cancellation tests drive the actor through:
    /// everything after a probe — renaming, reporting a loss, a stop racing a
    /// re-probe — is reachable from here with packets handed to
    /// ``receive(_:on:)``, and none of it needs the network.
    func assume(_ descriptor: ServiceDescriptor, attempt: Int) throws {
        txt = try Self.wireRecord(descriptor)
        self.descriptor = descriptor
        self.attempt = attempt
        phase = .established
    }

    static func wireRecord(_ descriptor: ServiceDescriptor) throws -> [UInt8] {
        Array(try descriptor.txtRecord().dnsSDWireFormat)
    }
}

enum MDNSAnnouncerError: Error, Equatable, CustomStringConvertible {
    case namesTaken(attempts: Int)
    case notEstablished

    var description: String {
        switch self {
        case .namesTaken(let attempts):
            "another device on this network already uses this name, and \(attempts - 1) alternatives were taken too"
        case .notEstablished:
            "skrepkad's own mDNS responder stopped before it finished claiming its name"
        }
    }
}
