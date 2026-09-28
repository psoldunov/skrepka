import Foundation
import SkrepkaSync

/// What the Linux side says when a dial of its own did not reach the peer.
///
/// `SkrepkaSync` classifies and owns no words; the Mac's are in
/// `SyncFailureText`. These are the daemon's, for the two places its dials
/// surface: a paired peer's link state, which the peer list shows after
/// "failed: ", and a dial to pair, which `skrepka pair` and Settings print.
extension DialFailure {
    /// The reason in a link's `failed: …` state — lower case, because it
    /// follows a colon in every surface that shows it.
    var linkReason: String {
        switch self {
        case .noAnswer: "no answer — it may be asleep, or a firewall on it may be blocking Skrepka"
        case .refused: "refused — Skrepka is not listening there"
        case .unreachable: "no route to it from this network"
        case .notFound: "its address did not resolve on this network"
        }
    }

    /// Why a dial to pair with `peer` on `port` failed, as a sentence.
    func pairingSentence(peer: String, port: UInt16) -> String {
        switch self {
        case .noAnswer:
            """
            "\(peer)" did not answer on TCP port \(port). Either it went to sleep, or a \
            firewall on it is dropping the connection — on a Linux machine, allow that port \
            there, and the sync port its `skrepka doctor` lists.
            """
        case .refused:
            """
            "\(peer)" refused the connection on TCP port \(port), so nothing is listening \
            there any more. Its pairing window may have just closed — open it again and retry.
            """
        case .unreachable:
            """
            "\(peer)" cannot be reached from this network. Check that both machines are on \
            the same one.
            """
        case .notFound:
            """
            "\(peer)"'s address did not resolve. Check that both machines are on the same \
            network.
            """
        }
    }

    /// A link's failure reason: the classified one where there is one, and
    /// the error's own description — a TLS or protocol refusal, which has its
    /// own precise wording — where there is not.
    static func linkReason(for error: any Error) -> String {
        DialFailure(error)?.linkReason ?? String(describing: error)
    }
}
