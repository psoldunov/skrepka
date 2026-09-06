import Foundation

/// Whether a clipping captured on this device may be handed to peers live.
///
/// A pure function rather than three conditions inside a coordinator, because
/// the two rules it holds are the ones that are expensive to get wrong and
/// impossible to see going wrong:
///
/// - **Concealed content never crosses.** D-7, and the receiving half is
///   enforced again in every `HistoryStoring` conformance — this is the sending
///   half, and it is the one a caller could omit without anything failing.
/// - **Content a peer pushed here a moment ago is not pushed back.** The
///   `ClipboardWatcher.pause()` / `resume()` pair is what ordinarily stops the
///   watcher seeing a received write at all, and this is what stops the failure
///   *escalating* when that window is missed: not a duplicate row, but a loop
///   between two machines that neither one can see.
///
/// Whether a *particular peer* takes live pushes is a separate question with a
/// separate answer — see ``LivePushSetting/isOn`` — because it is per pair and
/// this is per clipping.
public enum LivePushGate {
    /// Whether this clipping may be offered to any peer at all.
    ///
    /// - Parameters:
    ///   - recentlyReceived: hashes accepted from peers lately. Passed in rather
    ///     than owned here so the caller keeps one set across every peer, which
    ///     is what makes "do not push this back" mean "to anybody".
    ///   - now: the instant the entries are aged against.
    public static func isPushable(
        contentHash: String,
        isConcealed: Bool,
        recentlyReceived: RecentHashes,
        at now: Date
    ) -> Bool {
        guard !isConcealed else { return false }
        return !recentlyReceived.contains(contentHash, at: now)
    }
}
