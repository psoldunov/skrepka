import Foundation

/// Why a discovery operation failed, named far enough to tell the user
/// something true.
///
/// "Why can I not see my other machine" has several different answers — no
/// responder running, a name that would not register, a peer that answered a
/// browse and then would not resolve — and a single opaque error tells the user
/// none of them.
public enum DiscoveryError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The platform has no working responder: no `mDNSResponder`, no
    /// `avahi-daemon`, or one that refused the connection.
    case responderUnavailable(reason: String)

    /// ``PeerDiscovery/startAdvertising(_:)`` was called while an
    /// advertisement was already published. Stop the first one; two records for
    /// one device is a peer that appears twice.
    case alreadyAdvertising

    /// The record could not be published.
    case advertisingFailed(reason: String)

    /// The advertisement was accepted and then withdrawn by the responder, or
    /// the responder itself went away.
    case advertisingLost(reason: String)

    /// The browse could not be started, or stopped working, and will not
    /// recover on its own.
    case browsingFailed(reason: String)

    /// The browse is alive but temporarily cannot run — no connectivity yet, or
    /// Local Network access not granted. Its own case because the answer for
    /// the user is "wait" rather than "something broke", and because the
    /// responder is expected to come back without being restarted.
    case browsingStalled(reason: String)

    /// The platform refused the operation because this program has not been
    /// granted access to the local network.
    ///
    /// Its own case because it is the one discovery failure with a specific
    /// answer — a switch in System Settings — and because nothing about the
    /// network is wrong. macOS 15 and later spell it `kDNSServiceErr_PolicyDenied`
    /// (-65570), which arrives from `DNSServiceRegister`, from
    /// `DNSServiceResolve`, and inside the `.waiting` state of an `NWBrowser`.
    ///
    /// It does not only mean "the user said no". TN3179 (*Understanding local
    /// network privacy*) says the system denies the operation immediately, before
    /// the user has answered the alert it raised, so this is also what an
    /// unanswered prompt looks like from here.
    case localNetworkDenied

    /// A peer that answered a browse could not be turned into a host and port.
    case resolutionFailed(peer: String, reason: String)

    /// Resolution produced nothing before the caller's deadline. Its own case
    /// because it is the one failure that is usually about the network rather
    /// than about the peer.
    case resolutionTimedOut(peer: String)

    /// A peer resolved, and its TXT record did not read as an advertisement.
    ///
    /// Named rather than dropped, which is the rule the whole
    /// ``AdvertisementError`` set exists for.
    case malformedAdvertisement(peer: String, error: AdvertisementError)

    public var description: String {
        switch self {
        case .responderUnavailable(let reason):
            "no mDNS responder available: \(reason)"
        case .alreadyAdvertising:
            "already advertising"
        case .advertisingFailed(let reason):
            "could not publish the service: \(reason)"
        case .advertisingLost(let reason):
            "the published service was withdrawn: \(reason)"
        case .browsingFailed(let reason):
            "could not browse for peers: \(reason)"
        case .browsingStalled(let reason):
            "cannot browse for peers at the moment: \(reason)"
        case .localNetworkDenied:
            "local network access has not been granted to this app"
        case .resolutionFailed(let peer, let reason):
            "could not resolve \"\(peer)\": \(reason)"
        case .resolutionTimedOut(let peer):
            "\"\(peer)\" did not resolve in time"
        case .malformedAdvertisement(let peer, let error):
            "\"\(peer)\" advertises a record this build cannot read: \(error)"
        }
    }
}
