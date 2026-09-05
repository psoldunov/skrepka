import Foundation
import SkrepkaSync

/// When a deletion's record stops being honoured — asked in one place, so the
/// two storage engines and `MergeEngine` cannot answer it differently.
///
/// **Pruning a tombstone one instant before the merge engine stops honouring it
/// resurrects deleted content.** A tombstone is the only record that a deletion
/// happened, so once it is gone a peer that still holds the item offers it back
/// and nothing refuses the offer. Erring long costs one row per deletion for a
/// little longer; erring short destroys the guarantee the feature exists for.
/// That asymmetry is why this type exists instead of `deleted_at <= now -
/// retention` written out once per engine, where a boundary the two spell
/// differently would be a silent data-loss bug.
enum TombstoneExpiry {
    /// Whether a deletion recorded at `deletedAt` may be dropped at `now`.
    ///
    /// `Tombstone.isExpired(at:)` itself — the merge engine's own rule, called
    /// rather than restated, so there is no second expression that could drift
    /// from it. Every prune on either engine decides with this and nothing else.
    ///
    /// The device identifier plays no part in expiry, so a stand-in stands in
    /// for it. That also means a row whose stored identifier will not parse is
    /// still prunable — worth having, because such a row is invisible to
    /// `tombstones(since:)` and would otherwise be the one thing that
    /// accumulates forever.
    static func isExpired(deletedAt: Date, at now: Date) -> Bool {
        Tombstone(contentHash: "", deletedAt: deletedAt, deviceID: unusedDevice)
            .isExpired(at: now)
    }

    /// The instant a prune may stop looking, for narrowing a query.
    ///
    /// **A hint, never the decision.** `Date` arithmetic is `Double`
    /// arithmetic, so `deletedAt <= now - retention` and `now - deletedAt >=
    /// retention` need not agree in the last bit. Selecting with this and
    /// deciding with ``isExpired(deletedAt:at:)`` makes that irrelevant: a row
    /// the hint misses is kept for another prune, and a row it over-selects is
    /// refused by the rule. Neither outcome can drop a tombstone the merge
    /// engine would still honour.
    static func candidateCutoff(now: Date) -> Date {
        now.addingTimeInterval(-SyncLimits.tombstoneRetention)
    }

    /// A `SyncDeviceID` for the one question that does not depend on one.
    ///
    /// Derived rather than a literal because `SyncDeviceID.init(hex:)` is
    /// failable; nothing ever compares or stores this value.
    private static let unusedDevice = SyncDeviceID(certificateDER: Data())
}
