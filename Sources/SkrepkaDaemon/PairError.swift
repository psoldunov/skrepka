import Foundation

/// Why a dial-to-pair could not be started.
///
/// Its own file rather than the foot of `Daemon+Actions.swift`: one primary
/// type per file, and that extension reached the 300-line limit once the dial
/// gained a deadline.
public enum PairError: Error, Sendable, CustomStringConvertible {
    case notOnTheNetwork(String)
    case notAcceptingPairing(String)
    /// The dial or the exchange did not finish within ``Daemon/pairDialTimeout``.
    case tookTooLong(String)

    public var description: String {
        switch self {
        case .tookTooLong(let fingerprint):
            """
            "\(fingerprint)" did not finish pairing in time. \
            That device may still be showing a pairing prompt for this one — refuse it \
            there before trying again, or the two will disagree about whether they are \
            paired. Then check that both are on the same network and that a pairing \
            window is still open on that one.
            """
        case .notOnTheNetwork(let fingerprint):
            """
            No single device on this network matches "\(fingerprint)". \
            Run `skrepka peers` to see what is visible.
            """
        case .notAcceptingPairing(let fingerprint):
            """
            "\(fingerprint)" is not accepting new pairings. \
            Open a pairing window on that device first — `skrepka pair` on Linux, or \
            the Sync pane in Settings on a Mac.
            """
        }
    }
}
