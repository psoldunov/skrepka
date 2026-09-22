import SkrepkaSync

/// A peer seen on the network, with the record it advertised.
struct Sighting: Sendable {
    let peer: DiscoveredPeer
    let advertisement: PeerAdvertisement
}
