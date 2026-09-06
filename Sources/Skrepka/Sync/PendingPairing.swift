import Foundation
import Observation
import SkrepkaSync

/// The pairing the user is looking at, as the sheet reads it.
///
/// An observable class rather than a value on the coordinator, because it
/// changes *while the sheet is open*: the device that started the pairing shows
/// the code straight away and then waits for the other end's user, and a sheet
/// that could not change would have to be closed and reopened to say so.
@MainActor
@Observable
final class PendingPairing: Identifiable {
    /// Which side asked.
    enum Direction: Sendable, Hashable {
        /// This device dialled. The other end's user answers first.
        case outgoing
        /// A peer dialled this device.
        case incoming
    }

    enum Stage: Sendable, Hashable {
        /// Sent, and the other end's user has not answered. Only ``outgoing``
        /// reaches this.
        case waitingForPeer
        /// The code is on both screens and this user has to decide.
        case awaitingConfirmation
        /// The other end said no, or the exchange failed. Carries what to show.
        case ended(reason: String)
    }

    let id = UUID()
    let direction: Direction
    /// What the peer calls itself. Advisory — it is a label the peer chose, not
    /// an identity.
    let peerName: String
    /// The short form of the peer's identifier, which is an identity.
    let fingerprint: String
    /// The eight characters the two users compare, already grouped `A3F2-91BC`.
    let code: String

    var stage: Stage

    init(
        direction: Direction,
        peerName: String,
        fingerprint: String,
        code: String,
        stage: Stage
    ) {
        self.direction = direction
        self.peerName = peerName
        self.fingerprint = fingerprint
        self.code = code
        self.stage = stage
    }

    /// Whether the sheet's confirm button should do anything yet.
    var canConfirm: Bool { stage == .awaitingConfirmation }
}
