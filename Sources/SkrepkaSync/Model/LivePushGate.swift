import Foundation

/// Whether a clipping captured on this device may be handed to peers live.
///
/// Rules rather than conditions inside a coordinator, because the ones held
/// here are expensive to get wrong and impossible to see going wrong:
///
/// - **Concealed content never crosses.** D-7, and the receiving half is
///   enforced again in every `HistoryStoring` conformance — this is the sending
///   half, and it is the one a caller could omit without anything failing.
/// - **Content a peer handed to this clipboard is not pushed back.** The write
///   itself is kept out of capture where it is made — the Mac pauses its
///   watcher around a synchronous write, the Linux sessions drop their own
///   echo — and this is what stops the failure *escalating* when that misses:
///   ``ClipboardHandoff`` refuses the hash for as long as nothing else has been
///   copied, and ``RecentHashes`` for thirty seconds, which still covers the
///   older pushes of a burst. Missing both is not a duplicate row but a loop
///   between machines that neither one can see.
///
/// **One value holding both memories, not a function over two.** The hand-over
/// has to hear about a copy *before* the copy is judged, or a copy of
/// something new is judged against a hand-over it has already ended — and
/// that order was once written out by every caller. ``admitCopy(_:isConcealed:at:)``
/// hears and judges in one call, so there is no order left to get wrong.
///
/// The owner is the coordinator on each platform, one per device, which is what
/// makes "do not push this back" mean "to anybody": `SyncCoordinator` on the
/// Mac, already `@MainActor`, and the `Daemon` actor on Linux.
///
/// Whether a *particular peer* takes live pushes is a separate question with a
/// separate answer — see ``LivePushSetting/isOn`` — because it is per pair and
/// this is per clipping.
public struct LivePushGate: Sendable {
    private var recentlyReceived = RecentHashes()
    private var handoff = ClipboardHandoff()
    /// A push that arrived without its bytes and may still be written once
    /// they land. Cleared by anything that makes it no longer the newest
    /// thing the user would expect on the clipboard.
    private var awaitingBytes: String?

    public init() {}

    /// A peer's push is about to be written to this device's clipboard.
    ///
    /// Called **before** the write, not after: the write is what the watcher
    /// might see, so a guard updated afterwards would be updated after the race
    /// it exists to lose.
    ///
    /// Supersedes a push still waiting for its bytes, unless it is that push.
    public mutating func noteReceived(_ contentHash: String, at now: Date) {
        recentlyReceived.remember(contentHash, at: now)
        handoff.received(contentHash)
        if awaitingBytes != contentHash { awaitingBytes = nil }
    }

    /// A peer pushed this without its bytes, and they are being fetched — see
    /// `PeerLink.fetchPushed(_:)`. Nothing is written yet.
    ///
    /// Replaces any push already waiting: the newest one is the only one worth
    /// putting on the clipboard.
    public mutating func noteAwaitingBytes(_ contentHash: String) {
        awaitingBytes = contentHash
    }

    /// The bytes of a push that arrived without them have landed: whether they
    /// may be written to the clipboard now. When the answer is yes the write is
    /// already noted, exactly as ``noteReceived(_:at:)`` would — so a caller
    /// writes straight after a `true` and calls nothing else first.
    ///
    /// No when anything happened since the push that the user would expect to
    /// find on the clipboard instead: a copy on this device, recorded or not,
    /// or another push written. Minutes-late bytes replacing what the user
    /// just copied is the failure this exists to prevent; the item is in
    /// history either way.
    public mutating func claimFetched(_ contentHash: String, at now: Date) -> Bool {
        guard awaitingBytes == contentHash else { return false }
        awaitingBytes = nil
        noteReceived(contentHash, at: now)
        return true
    }

    /// Something was copied on this device and recorded: whether it may be
    /// offered to any peer at all.
    ///
    /// Call it for every recorded copy, whether or not any peer takes live
    /// pushes right now — sync being off has no bearing on whether the user
    /// has copied something new, and a copy the gate never heard of would
    /// leave the last push handed over for good.
    ///
    /// - Parameter now: the instant the hash window is aged against.
    public mutating func admitCopy(
        _ contentHash: String,
        isConcealed: Bool,
        at now: Date
    ) -> Bool {
        handoff.captured(contentHash)
        awaitingBytes = nil
        guard !isConcealed, !handoff.isHandedOver(contentHash) else { return false }
        return !recentlyReceived.contains(contentHash, at: now)
    }

    /// Something was copied on this device and not recorded — refused by the
    /// capture rules, or lost to a store that failed.
    ///
    /// Nothing is offered, but it is still a copy, so it ends a hand-over the
    /// way a recorded one does. Pass the hash when there is one: the
    /// handed-over content coming back unrecorded is still the hand-over.
    public mutating func noteUnrecordedCopy(_ contentHash: String? = nil) {
        handoff.captured(contentHash)
        awaitingBytes = nil
    }
}
