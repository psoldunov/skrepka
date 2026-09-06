import Foundation

/// A peer resolved far enough to dial.
///
/// Discovery has to produce this rather than stopping at a name, because the
/// transport is swift-nio on both platforms and NIO connects to a host and a
/// port. Network framework would have taken the service endpoint directly; NIO
/// cannot, so resolution is discovery's job here rather than the connector's.
public struct ResolvedPeer: Sendable, Hashable {
    /// The browse result this came from, so a caller can resolve again later
    /// without re-browsing.
    public let peer: DiscoveredPeer

    /// The SRV target — a host *name*, usually `something.local.`, not an
    /// address.
    ///
    /// Left as a name on purpose. Both platforms resolve `.local.` through the
    /// responder already running on them, and turning it into an address here
    /// would pin one of the peer's addresses at resolve time and keep using it
    /// after the peer moved networks.
    public let host: String

    /// In host byte order. `DNSServiceResolve` reports it in network byte
    /// order, and the conformance converts.
    public let port: UInt16

    /// The record as it stood at resolution, which is fresher than anything a
    /// browse result carried.
    public let advertisement: PeerAdvertisement

    public init(
        peer: DiscoveredPeer,
        host: String,
        port: UInt16,
        advertisement: PeerAdvertisement
    ) {
        self.peer = peer
        self.host = host
        self.port = port
        self.advertisement = advertisement
    }
}
