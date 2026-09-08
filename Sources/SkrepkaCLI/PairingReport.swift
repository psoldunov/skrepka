import Foundation
import SkrepkaIPC

/// The block `skrepka pair` prints while a person compares two screens.
///
/// **The short authentication string is the whole security of pairing.** It is
/// derived from both certificates, so somebody sitting in the middle of the
/// handshake produces two different strings and the two screens disagree. That
/// only protects anybody if the words are impossible to miss and the
/// instruction to compare them is impossible to read as optional — which is why
/// this is a framed block on its own rather than a line among the peer's
/// details.
public enum PairingReport {
    public static func text(
        _ proposal: PairingProposalDocument,
        timeZone: TimeZone = .current
    ) -> String {
        let rule = String(repeating: "=", count: 64)
        let who = proposal.name ?? "an unnamed device"
        let how =
            proposal.direction == PairingProposalDocument.Direction.incoming
            ? "\(who) (\(proposal.platform)) is asking to pair with this device."
            : "Pairing with \(who) (\(proposal.platform))."
        return """
            \(rule)
            \(how)

                \(proposal.shortAuthString)

            These words must appear on the other device as well. If they differ,
            or you cannot see them there, answer no — somebody else is on the
            wire and answering yes would pair with them.
            \(rule)
            fingerprint  \(proposal.fingerprint)
            expires      \(HistoryReport.stamp(proposal.expiresAt, in: timeZone))
            """
    }
}
