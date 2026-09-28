import Foundation
import SkrepkaSync

/// What one paired peer's link is doing, for the peer list.
struct PeerProgress: Sendable, Hashable {
    var state = "idle"
    var name: String?
    var platform: PeerPlatform = .unknown
    var lastSyncedAt: Date?
    /// This link's first successful exchange since it last failed — how long
    /// the peer has been awake and reachable, which is what ``InboundSilence``
    /// measures its silence against.
    var firstSyncedAt: Date?
}
