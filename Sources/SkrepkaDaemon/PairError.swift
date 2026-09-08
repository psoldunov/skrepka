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
    /// The caller passed an empty or whitespace-only fingerprint, which would
    /// otherwise prefix-match every device on the network.
    case noDeviceNamed

    public var description: String {
        switch self {
        case .noDeviceNamed:
            Daemon.blankSelectorDetail
        case .tookTooLong(let fingerprint):
            """
            "\(fingerprint)" did not finish pairing in time. \
            \(PairError.oneSidedWarning) \
            Then check that both are on the same network and that a pairing \
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

    /// Said whenever a pairing ends after the *far* side may already have
    /// recorded this device.
    ///
    /// The responder saves the peer the moment its own human accepts — see
    /// `SyncResponder.answerPairRequest` — while this side saves only once the
    /// short authentication string has been confirmed here. So a dial that runs
    /// out of time, and an outgoing proposal refused at the string, both leave
    /// the other machine trusting this one while this one trusts nothing.
    ///
    /// Nothing unauthorised is created on this side by that, and it is not
    /// repaired on the wire: telling the far side to roll back would be a new
    /// message type. It is *reported* instead, here and in the journal, because
    /// a stale entry the user never hears about is the part that costs them.
    static let oneSidedWarning = """
        That device may now list this one as paired even though this one does not — \
        forget it there (`skrepka unpair` on Linux, or the Sync pane in Settings on a \
        Mac) before trying again, or the two will disagree about whether they are paired.
        """
}
