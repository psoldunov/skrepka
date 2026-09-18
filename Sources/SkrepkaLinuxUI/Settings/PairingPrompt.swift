import Foundation
import SkrepkaIPC

/// The one pairing a person is being asked about right now.
///
/// Both directions are the same prompt, because the thing the person does is
/// the same: read the code, check that the other screen shows exactly it, and
/// answer. What differs is how it starts — this device dials, or a peer dials
/// this one — and so the title.
public struct PairingPrompt: Sendable, Hashable {
    public enum Direction: Sendable, Hashable {
        /// This device dialled, from a row's Pair… button.
        case outgoing
        /// A peer dialled this device while its pairing window was open.
        case incoming
    }

    public enum Stage: Sendable, Hashable {
        /// Dialling, before there is a code. Outgoing only.
        case dialling
        /// The code is on screen and the person has not answered.
        case comparing
        /// The answer is on its way to the daemon.
        case answering(accept: Bool)
        /// It is over and did not pair; the sentence says why.
        case ended(String)

        /// Whether Cancel, Close, Escape or the title bar does anything here:
        /// everything but an answer already on its way, which the daemon
        /// cannot be asked to take back — ``SyncModel/cancellingPrompt(now:)``
        /// leaves that one alone.
        var isCancellable: Bool {
            if case .answering = self { return false }
            return true
        }
    }

    /// The device's full hex ID — what the answer names.
    public let deviceID: String
    public let name: String
    public let fingerprint: String
    public let direction: Direction
    /// The short authentication string. Nil only while dialling.
    public let code: String?
    /// When the daemon stops waiting for the answer and refuses on the
    /// person's behalf. Nil only while dialling.
    public let expiresAt: Date?
    public let stage: Stage

    /// What the prompt says when it runs out, which is the daemon refusing a
    /// pairing nobody confirmed — the macOS sheet's sentence for the same case.
    static let tookTooLong = "The pairing took too long to confirm. Start it again."

    /// What the prompt says when both devices dialled each other at once.
    static let crossed = """
        Both devices started pairing with each other at the same moment, so neither \
        pairing was kept. Start again from one of them.
        """

    /// A dial just started for a device in the list.
    static func dialling(_ peer: PeerDocument) -> PairingPrompt {
        PairingPrompt(
            deviceID: peer.deviceID,
            name: peer.name ?? peer.fingerprint,
            fingerprint: peer.fingerprint,
            direction: .outgoing,
            code: nil,
            expiresAt: nil,
            stage: .dialling
        )
    }

    /// A proposal with its code, in either direction.
    ///
    /// The dialling side's proposal carries no name — only the certificate is
    /// known there — so the name the row showed is kept when there is one.
    static func comparing(_ proposal: PairingProposalDocument, knownName: String? = nil) -> PairingPrompt {
        PairingPrompt(
            deviceID: proposal.deviceID,
            name: proposal.name ?? knownName ?? proposal.fingerprint,
            fingerprint: proposal.fingerprint,
            direction: proposal.direction == PairingProposalDocument.Direction.incoming
                ? .incoming : .outgoing,
            code: proposal.shortAuthString,
            expiresAt: proposal.expiresAt,
            stage: .comparing
        )
    }

    func moved(to stage: Stage) -> PairingPrompt {
        PairingPrompt(
            deviceID: deviceID,
            name: name,
            fingerprint: fingerprint,
            direction: direction,
            code: code,
            expiresAt: expiresAt,
            stage: stage
        )
    }

    var isOver: Bool {
        if case .ended = stage { return true }
        return false
    }
}
