import Foundation
import SkrepkaIPC
import SkrepkaSync

/// A pairing waiting for somebody to say yes or no.
///
/// ## Why this is not a `CheckedContinuation`
///
/// The macOS coordinator parks the responder on a `withCheckedContinuation`
/// resumed by a button in a sheet. That works because there is always a window
/// and always a user in front of it. Here there may be no client attached at
/// all: `skrepkad` runs under systemd and `skrepka pair` may never be typed.
///
/// A continuation that is never resumed is a task suspended for the life of the
/// process, holding a connection and a file descriptor, with nothing anywhere
/// saying so. So the answer arrives through a one-element `AsyncStream` with a
/// deadline on the read: `answer(_:)` yields, the timeout finishes without
/// yielding, and either way the wait ends. A stream cannot be resumed twice and
/// cannot be dropped.
///
/// The default when nobody answers is **refusal**. A pairing accepted because
/// no one was watching is the one outcome this design must not have.
struct PendingPairing: Sendable {
    /// Distinguishes one proposal from the next for the same device.
    ///
    /// A peer that dials twice replaces its own entry in `Daemon.pending`, and
    /// the replaced wait then finishes and clears that entry — so without a
    /// way to ask "is the entry still mine?", a retry deleted its own proposal
    /// the moment the one it replaced timed out, and could never be answered.
    let id = UUID()

    /// The peer exactly as the exchange proved it.
    ///
    /// Held whole, rather than only the fields the document shows, because the
    /// side that *dialled* has to write the record itself when the answer is
    /// yes — and it has to write it before it reports "paired". See
    /// ``Daemon/answerPairing(deviceID:accept:)``.
    let peer: PairedPeer

    let deviceID: SyncDeviceID
    let fingerprint: String
    let name: String?
    let platform: PeerPlatform
    let shortAuthString: String
    let direction: String
    let expiresAt: Date

    /// Yielding to this is how an answer reaches the parked responder.
    private let sink: AsyncStream<Bool>.Continuation

    init(
        proposal: PairingProposal,
        direction: String,
        expiresAt: Date,
        sink: AsyncStream<Bool>.Continuation
    ) {
        peer = proposal.peer
        deviceID = proposal.peer.deviceID
        fingerprint = proposal.peer.deviceID.fingerprint
        // The dialling side records the fingerprint as a name, because a
        // pairing-policy connection carries no `hello` — so a name that is just
        // the fingerprint again is worth reporting as no name at all.
        let claimed =
            proposal.peer.deviceName == proposal.peer.deviceID.fingerprint
            ? nil : proposal.peer.deviceName
        // Sanitised because this one is the worst of them: it arrives on an
        // unauthenticated pairing connection from whoever is on the LAN, and
        // it is printed straight into the terminal of whoever ran
        // `skrepka pair` — the case `SafeText` calls the more serious half.
        name = SafeText.oneLine(ifPresent: claimed, limit: SafeText.nameLimit)
        platform = proposal.peer.platform
        shortAuthString = proposal.shortAuthenticationString
        self.direction = direction
        self.expiresAt = expiresAt
        self.sink = sink
    }

    /// Answers, and ends the wait. Answering twice is harmless — the second
    /// yield lands in a finished stream and is dropped.
    func answer(_ accepted: Bool) {
        sink.yield(accepted)
        sink.finish()
    }

    /// Gives up waiting, which means refusing.
    func expire() {
        sink.finish()
    }

    var document: PairingProposalDocument {
        PairingProposalDocument(
            deviceID: deviceID.hex,
            fingerprint: fingerprint,
            name: name,
            platform: platform.rawValue,
            shortAuthString: shortAuthString,
            direction: direction,
            expiresAt: expiresAt
        )
    }
}
