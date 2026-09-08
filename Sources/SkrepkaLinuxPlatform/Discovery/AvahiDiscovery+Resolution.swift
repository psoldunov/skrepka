import DBUS
import Foundation
import SkrepkaSync

extension AvahiDiscovery {
    /// Turns a browse result into a host, a port and the peer's record.
    ///
    /// This is where a Linux peer's TXT record comes from at all: avahi's
    /// browse signals carry none, so every ``SkrepkaSync/DiscoveredPeer`` from
    /// this backend is ``SkrepkaSync/DiscoveredPeer/AdvertisementState/unread``
    /// until it has been through here.
    ///
    /// A resolver is created, listened to once, and freed. Keeping one alive
    /// per peer would be avahi's own recommendation for a long-running browse,
    /// and it is the wrong shape for this protocol: a peer's address outlives
    /// neither sleep nor a network change, so the answer is only true at the
    /// moment it is asked for, and callers are told to resolve immediately
    /// before connecting.
    public func resolve(_ peer: DiscoveredPeer, timeout: Duration) async throws -> ResolvedPeer {
        let found = try await signals(
            interface: AvahiNames.Interface.serviceResolver, member: AvahiNames.Resolver.found)
        let failures = try await signals(
            interface: AvahiNames.Interface.serviceResolver, member: AvahiNames.Resolver.failure)

        let path = try await newResolver(for: peer)
        defer {
            Task { [weak self] in
                await self?.free(
                    path: path,
                    interface: AvahiNames.Interface.serviceResolver,
                    method: AvahiNames.Resolver.free
                )
            }
        }

        return try await withDeadline(timeout, peer: peer) {
            try await Self.firstAnswer(found: found, failures: failures, at: path, for: peer)
        }
    }

    /// The first of a `Found`, a `Failure`, or neither.
    ///
    /// `nonisolated static` on purpose: it runs inside a task group whose child
    /// tasks must not hop back onto this actor for every message that arrives
    /// for some other resolver.
    private nonisolated static func firstAnswer(
        found: AsyncStream<DBusMessage>,
        failures: AsyncStream<DBusMessage>,
        at path: String,
        for peer: DiscoveredPeer
    ) async throws -> ResolvedPeer {
        try await withThrowingTaskGroup(of: ResolvedPeer.self) { group in
            group.addTask {
                for await message in found {
                    guard message.path == path,
                        let resolution = AvahiSignals.resolution(message.body)
                    else { continue }
                    return try Self.resolved(peer, from: resolution)
                }
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName, reason: "avahi stopped answering")
            }
            group.addTask {
                for await message in failures {
                    guard message.path == path else { continue }
                    throw DiscoveryError.resolutionFailed(
                        peer: peer.instanceName,
                        reason: AvahiSignals.failureReason(message.body) ?? "the resolve failed"
                    )
                }
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName, reason: "avahi stopped answering")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DiscoveryError.resolutionFailed(
                    peer: peer.instanceName, reason: "avahi answered nothing")
            }
            return first
        }
    }

    /// Reads the record avahi resolved, and refuses a peer whose record this
    /// build cannot read.
    ///
    /// Named rather than dropped: a machine with a broken record should be
    /// visible and diagnosable rather than absent, which is the rule the whole
    /// `AdvertisementError` set exists for.
    private nonisolated static func resolved(
        _ peer: DiscoveredPeer,
        from resolution: AvahiSignals.Resolution
    ) throws -> ResolvedPeer {
        let advertisement: PeerAdvertisement
        do {
            advertisement = try PeerAdvertisement(
                txtRecord: TXTRecord(avahiEntries: resolution.txt))
        } catch let error as AdvertisementError {
            throw DiscoveryError.malformedAdvertisement(peer: peer.instanceName, error: error)
        } catch {
            throw DiscoveryError.malformedAdvertisement(
                peer: peer.instanceName,
                error: .malformedRecord(reason: String(describing: error))
            )
        }
        return ResolvedPeer(
            peer: peer,
            host: resolution.host,
            port: resolution.port,
            advertisement: advertisement
        )
    }

    private func newResolver(for peer: DiscoveredPeer) async throws -> String {
        let reply = try await callServer(
            AvahiNames.Server.serviceResolverNew,
            [
                .int32(peer.interfaceIndex.map { Int32($0) } ?? AvahiNames.unspecifiedInterface),
                .int32(AvahiNames.unspecifiedProtocol),
                .string(peer.instanceName),
                .string(peer.serviceType),
                .string(peer.domain),
                // `aprotocol` — which address family to resolve to. Unspecified,
                // because Skrepka connects to the `host` name rather than to the
                // address, and constraining it here would fail a resolve on a
                // peer that happens to be v6-only.
                .int32(AvahiNames.unspecifiedProtocol),
                .uint32(0),
            ]
        )
        guard case .objectPath(let path) = reply.first else {
            throw AvahiError.unreadableReply(method: AvahiNames.Server.serviceResolverNew)
        }
        return path
    }

    /// Runs `work` against the caller's deadline.
    ///
    /// A resolve is a multicast question and an answer from a machine on the
    /// same LAN. Avahi will keep a resolver waiting for a peer that has left
    /// for as long as the resolver exists, so the deadline has to come from
    /// this side.
    private nonisolated func withDeadline(
        _ timeout: Duration,
        peer: DiscoveredPeer,
        _ work: @escaping @Sendable () async throws -> ResolvedPeer
    ) async throws -> ResolvedPeer {
        try await withThrowingTaskGroup(of: ResolvedPeer.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw DiscoveryError.resolutionTimedOut(peer: peer.instanceName)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw DiscoveryError.resolutionTimedOut(peer: peer.instanceName)
            }
            return first
        }
    }
}
