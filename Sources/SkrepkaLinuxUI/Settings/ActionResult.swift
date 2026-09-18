import SkrepkaIPC

/// How one ``SyncAction`` ended.
public enum ActionResult: Sendable, Hashable {
    /// The daemon did it, or said in a sentence why it did not — see
    /// ``ActionDocument``'s rule for which of the two an answer is.
    case answered(ActionDocument)
    /// The pairing listener is open, until the document's expiry.
    case opened(PairingWindowDocument)
    /// A dial reached the device and there is a code to compare.
    case proposed(PairingProposalDocument)
    /// The call itself failed: the daemon was unreachable, too slow, or
    /// refused the call rather than answering it.
    case failed(SyncFailure)
}
