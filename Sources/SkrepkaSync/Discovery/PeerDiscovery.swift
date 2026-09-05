import Foundation

/// Publishing this device on the local network, and finding the others.
///
/// Three conformances across the project's life, and the shape below is what
/// all three can honestly implement rather than what any one of them makes
/// easiest:
///
/// - **`BonjourDiscovery`** (this phase, macOS). Browses with `NWBrowser`,
///   publishes with `DNSServiceRegister` and resolves with
///   `DNSServiceResolve`. Publishing cannot use `NWListener`: an `NWListener`
///   binds a socket of its own, so it cannot advertise the port swift-nio is
///   already listening on — measured, not assumed, and recorded in
///   ``BonjourDiscovery``.
/// - **`AvahiDiscovery`** (Phase 6, Linux, where `avahi-daemon` runs). Talks to
///   `org.freedesktop.Avahi` over D-Bus. ``startAdvertising(_:)`` becomes
///   `Server.EntryGroupNew` then `EntryGroup.AddService` and `Commit`;
///   ``startBrowsing()`` becomes `ServiceBrowserNew` and its `ItemNew` /
///   `ItemRemove` signals; ``resolve(_:timeout:)`` becomes
///   `ServiceResolverNew`. Two things about it shaped this protocol: avahi's
///   browse signals carry no TXT record, which is why ``DiscoveredPeer`` has an
///   ``DiscoveredPeer/AdvertisementState/unread`` state rather than an
///   optional advertisement; and `AddService` takes `txt` as `aay`, raw
///   `key=value` byte arrays, which is why ``TXTRecord`` is ordered byte pairs
///   with ``TXTRecord/avahiEntries`` rather than a `[String: String]`.
/// - **`EmbeddedMDNSDiscovery`** (Phase 6, Linux, where it does not). A
///   vendored mDNS responder owning its own multicast socket. It needs exactly
///   what avahi needs — no TXT until a resolve, an interface index to send
///   queries on, and an event stream rather than a snapshot — plus the ability
///   to fail at construction, which ``DiscoveryError/responderUnavailable``
///   covers: co-binding UDP 5353 works for multicast but only one process
///   receives unicast replies, so this conformance is the fallback and must be
///   able to say it cannot run.
///
/// Constrained to `Actor` rather than `Sendable`. Every conformance owns
/// mutable machinery that callbacks from another thread write into — a
/// `DNSServiceRef`, a D-Bus connection, a multicast socket — which the repo's
/// conventions say belongs in an actor, and inheriting the isolation here saves
/// each conformance from restating it.
public protocol PeerDiscovery: Actor {
    /// Publishes this device.
    ///
    /// Returns once the responder has confirmed the registration, so
    /// ``registration`` is readable afterwards. Throws
    /// ``DiscoveryError/alreadyAdvertising`` rather than replacing a live
    /// advertisement: one device publishing two records appears twice, and the
    /// caller that wanted a change should stop the first one.
    func startAdvertising(_ descriptor: ServiceDescriptor) async throws

    /// What the responder granted, or `nil` when nothing is published.
    ///
    /// Not the same as what was asked for. See ``ServiceRegistration``.
    var registration: ServiceRegistration? { get }

    /// Reports an advertisement that was confirmed and then stopped being
    /// published.
    ///
    /// Separate from ``startAdvertising(_:)`` throwing because the two failures
    /// happen at different times. `startAdvertising(_:)` covers everything up
    /// to the responder's confirmation; everything after it arrives here — a
    /// name conflict the responder could not rename around, or the responder
    /// itself dying. dns_sd.h:1275-1284 makes that second answer part of the
    /// `DNSServiceRegister` contract, and avahi's `EntryGroup.StateChanged`
    /// signal carries the same fact as `ENTRY_GROUP_COLLISION` and
    /// `ENTRY_GROUP_FAILURE`, so both backends have something real to put here.
    /// Without it a device drops off the network with nothing anywhere saying
    /// so.
    ///
    /// Each caller gets its own stream and every stream sees every loss. A
    /// stream finishes at ``stopAdvertising()``, which the loss itself
    /// triggers, so a `for await` over it ends one element after the failure it
    /// reported.
    func advertisementFailures() -> AsyncStream<DiscoveryError>

    /// Withdraws the advertisement. Idempotent, and does not throw: teardown
    /// that can fail is teardown a caller cannot write correctly.
    func stopAdvertising()

    /// Starts browsing for `_skrepka._tcp` peers.
    ///
    /// **Each caller gets its own stream, and every stream sees every event.**
    /// One browse runs however many callers there are: calling this a second
    /// time subscribes to the browse already running rather than starting a
    /// second responder query. Handing back one shared `AsyncStream` instead
    /// would look like the same thing and is not — a stream has one buffer and
    /// delivers each element to exactly one consumer, so a peer list and a
    /// pairing coordinator reading the same stream would split the peers
    /// between them and each show a subset. A stream whose consumer stops
    /// reading is dropped, and the browse carries on for the rest.
    ///
    /// Every stream stays open until ``stopBrowsing()`` or until the browse
    /// fails: ``DiscoveryEvent/failed(_:)`` is terminal and the stream finishes
    /// immediately after it. Calling this again after that starts a fresh
    /// browse, which is what browser.h:68-72 requires of `NWBrowser` and what
    /// avahi's `ServiceBrowser` needs after a `Failure` signal.
    func startBrowsing() throws -> AsyncStream<DiscoveryEvent>

    /// Stops browsing and finishes every stream ``startBrowsing()`` handed out.
    /// Idempotent.
    func stopBrowsing()

    /// Turns a browse result into a host and a port.
    ///
    /// Separate from browsing rather than folded into it because a peer's
    /// address outlives neither sleep nor a network change, so the answer is
    /// only true at the moment it is asked for. Call it immediately before
    /// connecting, not once at discovery time.
    func resolve(_ peer: DiscoveredPeer, timeout: Duration) async throws -> ResolvedPeer
}

extension PeerDiscovery {
    /// How long a resolution waits before giving up.
    ///
    /// A resolve is a multicast question and an answer from a machine on the
    /// same LAN. Five seconds is long enough for a sleeping peer's responder to
    /// wake and short enough that a peer which has left does not hold up a
    /// connection attempt.
    public static var defaultResolutionTimeout: Duration { .seconds(5) }

    public func resolve(_ peer: DiscoveredPeer) async throws -> ResolvedPeer {
        try await resolve(peer, timeout: Self.defaultResolutionTimeout)
    }
}
