import Foundation

/// What one outbound connection tells the coordinator about itself.
///
/// A closed set of events rather than the link exposing state to be polled: the
/// link is an actor and the coordinator is on the main actor, so every read
/// would be a hop and a snapshot that is already out of date. Reporting pushes
/// the hop to the moment something actually changed.
public enum PeerLinkEvent: Sendable, Hashable {
    /// Resolving and dialling. Reported before the network work starts, so a
    /// row that never gets further still shows the attempt.
    case connecting

    /// The tunnel is up and the peer identified itself inside it.
    ///
    /// Carries the name and platform from `hello`, which outrank the discovery
    /// record's: those arrived unauthenticated, these arrived inside the tunnel
    /// from the device whose certificate is pinned.
    case connected(name: String, platform: PeerPlatform)

    /// One index exchange finished. `learned` counts items this device did not
    /// have before.
    case synced(learned: Int, at: Date)

    /// One live push was written to the peer.
    case pushed

    /// The connection ended, or never started. The string is written for the
    /// settings pane rather than for a log.
    case failed(reason: String)
}
