import Foundation
import Logging
import SkrepkaIPC
import SkrepkaSync

// Which sync stack a piece of work belongs to.
//
// Sync turns off and on while the daemon runs (`SetSettings`), and work that
// captured the network half before an `await` can resume after
// `stopSyncStack(closingSystemBus:)` has already torn it down — a dial that
// lands, a proposal someone answers, a push a peer sent. `runtime != nil` is
// not the test: sync may have gone off and come back on during the await, and
// the new stack is not the one the work started under. So the stack carries a
// generation, bumped on every start and stop, and work compares the one it
// captured before its first await with the one live now.
extension Daemon {
    /// Whether work that began under `generation` may still act: it is the
    /// same stack, and the daemon is not stopping.
    ///
    /// No `runtime != nil` here, deliberately: every caller captured its
    /// generation where it had already required a runtime, and any stop since
    /// has bumped the generation — so an unchanged one means the stack is
    /// still the one that was running.
    func isSyncCurrent(_ generation: Int) -> Bool {
        !isStopping && syncGeneration == generation
    }

    /// Marks the start or end of a sync stack. Called by `startSync()` and
    /// `stopSyncStack(closingSystemBus:)`, and nowhere else.
    func advanceSyncGeneration() {
        syncGeneration &+= 1
    }

    /// Files an outgoing proposal whose dial began under `generation`, and
    /// starts waiting for its answer.
    ///
    /// Throws ``PairingWindowError/syncIsOff`` and files nothing when sync went
    /// off — or off and on again — while the dial was in flight: tear-down has
    /// already expired every pending proposal, and one filed after it would be
    /// answerable against a stack that no longer exists.
    func fileOutgoing(_ proposal: PairingProposal, generation: Int) throws -> PairingProposalDocument {
        guard isSyncCurrent(generation) else {
            logger.notice(
                "a dial to pair finished after sync was turned off; dropping it",
                metadata: ["peer": .string(proposal.peer.deviceID.fingerprint)])
            throw PairingWindowError.syncIsOff
        }
        let (answers, sink) = AsyncStream<Bool>.makeStream()
        let waiting = PendingPairing(
            proposal: proposal,
            direction: PairingDirection.outgoing,
            expiresAt: Date().addingTimeInterval(pairingAnswerTimeout.seconds),
            sink: sink
        )
        // One live proposal per peer, and both writers obey it — see
        // `confirmPairing(_:direction:generation:)`, which expires the same
        // way. Overwriting without expiring parked the displaced proposal for
        // the whole timeout with nothing able to answer it.
        pending[proposal.peer.deviceID]?.expire()
        pending[proposal.peer.deviceID] = waiting
        watchOutgoingAnswer(answers, proposal: proposal, proposalID: waiting.id)
        return waiting.document
    }
}
