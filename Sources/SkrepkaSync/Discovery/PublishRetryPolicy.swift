import Foundation

/// What to do about an advertisement that would not publish.
public enum PublishRecovery: Sendable, Hashable {
    /// Schedule nothing. The browse reaching ``DiscoveryEvent/ready`` is the
    /// retry, and it arrives by itself the moment macOS grants access.
    case waitForAccess

    /// Try again after this long.
    case retry(after: Duration)

    /// Out of attempts. Say so and stop.
    case giveUp
}

/// Whether a failed publish is worth trying again, and how soon.
///
/// **A pure decision, kept out of the coordinator because the two failures it
/// separates behave nothing alike and the difference is easy to lose.**
///
/// `DiscoveryError.localNetworkDenied` is not a fault and must not be retried on
/// a timer. It means macOS has not yet granted this app the local network, and
/// the browse is already the thing waiting for that: `NWBrowser` sits in
/// `.waiting` and returns to `.ready` by itself when the user answers the alert,
/// which drives `performPublish()` again. A retry loop on top of that would ask
/// the responder the same refused question every few seconds for as long as the
/// alert is on screen, and each refusal is another chance for macOS to decide it
/// has already told this app no.
///
/// Everything else — a registration the responder never confirmed, a name
/// conflict, a responder that was restarted underneath the app — is a fault, and
/// one nothing else will ever retry. The browse reaches `.ready` **once** on a
/// stable network with access already granted, so a publish that fails there and
/// is not retried never happens again: the switch reads on, peers appear, and
/// this Mac is never on the network.
public enum PublishRetryPolicy: Sendable {
    /// How long to wait before each attempt after a failure.
    ///
    /// Short, few and fixed. What this recovers from is a transient refusal from
    /// `mDNSResponder`, which is either over in seconds or not going to clear on
    /// its own — unlike ``PeerLink/retryDelays``, which climbs to a minute
    /// because it is waiting for a whole other machine to come back. Three
    /// attempts inside about twenty seconds, and then a sentence for the user.
    public static let delays: [Duration] = [.seconds(1), .seconds(5), .seconds(15)]

    /// What should happen after a publish failed, given how many times it has
    /// already been retried.
    ///
    /// - Parameter attempts: retries already made for this failure, so 0 the
    ///   first time. Reset by a publish that succeeds.
    public static func recovery(from error: any Error, afterAttempts attempts: Int) -> PublishRecovery {
        if let error = error as? DiscoveryError, error == .localNetworkDenied {
            return .waitForAccess
        }
        guard attempts >= 0, attempts < delays.count else { return .giveUp }
        return .retry(after: delays[attempts])
    }
}
