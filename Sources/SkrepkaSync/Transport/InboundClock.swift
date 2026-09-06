import Foundation

/// Bounds how far into the future a peer's timestamps may reach, by comparing
/// them against the receiver's own clock as the message arrives.
///
/// Every ordering the model does runs on the *sender's* wall clock:
/// ``LWWRegister/merged(with:)`` takes the later `timestamp`,
/// `SyncClipMeta.combining(_:)` takes the later `createdAt`,
/// ``Tombstone/merged(with:)`` takes the later `deletedAt`. Those rules make the
/// merge convergent, and convergent is not the same as correct — a Linux box
/// with a stale RTC and no NTP is an hour fast, and for that hour every value it
/// writes outranks every honest one. Its pin survives each later unpin from the
/// Mac, so the item re-pins itself; its clippings sit permanently at the top of
/// history.
///
/// The bound cannot live in the model. ``MergeEngine/plan(_:)`` is pure and
/// `MergeInput.now` is one sender-independent instant, not a second opinion
/// about what time it is. The transport is the only layer holding a clock the
/// peer did not supply, so the check is applied here, on receipt, before any
/// metadata reaches a merge.
///
/// **Refused rather than clamped.** Clamping a future timestamp back to the
/// receiver's clock is the obvious answer and it does not work: the peer still
/// holds the original, re-offers it on the next sync, and the clamp lands it on
/// a *new*, later receipt instant — so it beats the unpin the user made in
/// between, and beats the next one, and the next. Capping the overshoot at
/// ``SyncLimits/maximumClockSkew`` instead of at the receipt instant only makes
/// each round's win smaller. Either way the user's action is silently undone
/// every time the two machines meet, which is the failure this type exists to
/// stop, merely on a shorter cycle.
///
/// Refusing costs the other thing: a clipping made on the fast machine does not
/// arrive until its clock is fixed. That is a bounded, visible, self-healing
/// loss — an item missing on one machine — against an unbounded, invisible one,
/// and on a single user's own machines a five-minute window is never crossed by
/// ordinary drift. Only the future direction is bounded; a peer whose clock is
/// *behind* loses ties, which is annoying and not a livelock.
///
/// The refusal is currently silent, because `SkrepkaSync` has no logger. It
/// should be surfaced when one arrives — a peer whose items stop syncing with no
/// stated reason is a support question nobody can answer.
enum InboundClock {
    /// Whether an instant a peer stamped is close enough to this device's clock
    /// to be ordered against local writes.
    static func isPlausible(_ timestamp: Date, receivedAt now: Date) -> Bool {
        timestamp <= now.addingTimeInterval(SyncLimits.maximumClockSkew)
    }

    /// Both of the item's ordering fields have to hold: `createdAt` decides
    /// where the item sits in history, and `isPinned`'s timestamp decides
    /// whether a pin sticks. One item is accepted or refused whole, because a
    /// row carrying one field the merge trusts and one it does not is a shape
    /// nothing downstream knows how to reason about.
    static func isPlausible(_ meta: SyncClipMeta, receivedAt now: Date) -> Bool {
        isPlausible(meta.createdAt, receivedAt: now)
            && isPlausible(meta.isPinned.timestamp, receivedAt: now)
    }

    /// A tombstone stamped in the future would outlive its
    /// ``SyncLimits/tombstoneRetention`` window by the length of the skew, and
    /// would beat every honest record of the same deletion.
    static func isPlausible(_ tombstone: Tombstone, receivedAt now: Date) -> Bool {
        isPlausible(tombstone.deletedAt, receivedAt: now)
    }

    /// The items of an offer a merge is allowed to see.
    static func plausible(_ items: [SyncClipMeta], receivedAt now: Date) -> [SyncClipMeta] {
        items.filter { isPlausible($0, receivedAt: now) }
    }

    /// The deletions of an offer a merge is allowed to see.
    static func plausible(_ tombstones: [Tombstone], receivedAt now: Date) -> [Tombstone] {
        tombstones.filter { isPlausible($0, receivedAt: now) }
    }
}
