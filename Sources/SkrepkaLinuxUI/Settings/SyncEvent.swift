import SkrepkaIPC

/// What ``DaemonLink`` reports back to the window, from the concurrency pool,
/// through a ``MainLoopInbox``.
///
/// Every case is a `Sendable` value, which is the point: this is all that
/// crosses from the threads that talk to the daemon to the one that draws.
public enum SyncEvent: Sendable, Hashable {
    /// A poll answered.
    case refreshed(PeersDocument)
    /// A poll could not reach the daemon, or could not read its answer.
    case unreachable(SyncFailure)
    /// An action is over, one way or the other. `refreshed` is the peer list
    /// read straight afterwards, so the window never draws the action's
    /// outcome against a list from before it — nil when that read failed.
    case finished(SyncAction, ActionResult, refreshed: PeersDocument?)
    /// A peer dialled this device and a person has to compare codes.
    case pairingRequested(PairingProposalDocument)
    /// The link has closed what it opened and stopped. Nothing follows.
    case shutDown
}
