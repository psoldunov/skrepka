import Foundation
import SkrepkaSync

/// What one paired peer's link is doing, for the peer list.
struct PeerProgress: Sendable, Hashable {
    var state = "idle"
    var name: String?
    var platform: PeerPlatform = .unknown
    var lastSyncedAt: Date?
}
