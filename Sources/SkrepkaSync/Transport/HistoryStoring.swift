import Foundation

/// The narrowest view of a clipboard history that a sync connection needs.
///
/// A protocol because `SkrepkaSync` must build on Linux and `SkrepkaCore` does
/// not, so the store cannot be named here. The app target's `HistoryStore`
/// conforms to it; the Linux daemon's store will conform to the same thing; a
/// test conforms with a dictionary.
///
/// Deliberately six methods. Everything the transport does is metadata offers,
/// tombstones and one payload at a time, and any method beyond those would be
/// a decision the store is making on the protocol's behalf.
///
/// **Concealed content is filtered by the conformance, on both paths that can
/// emit it** — ``syncIndex(since:)`` and ``payload(for:key:)`` — never by a
/// caller. The storage boundary is the only honest place for that rule, because
/// nothing above it can tell concealed content apart from any other.
///
/// Filtering the index alone is not enough, and the reason is the shape of a
/// `contentHash`: it names content without carrying it, so a peer can ask for
/// one it was never offered. A conformance whose ``payload(for:key:)`` looked
/// content up by hash and no more would answer those questions, which turns a
/// paired peer into an oracle for whatever it can guess.
public protocol HistoryStoring: Sendable {
    /// Metadata for every syncable item created at or after `cursor`, or all of
    /// them when it is nil. Never includes concealed content.
    func syncIndex(since cursor: Date?) async throws -> [SyncClipMeta]

    /// Applies a merge plan.
    ///
    /// **Atomic per batch, not per plan, and a caller must not assume
    /// otherwise.** The SQLite engine does hold one transaction for the whole
    /// plan; the SwiftData one saves every `syncBatchSize` actions, because a
    /// single save over a 500-action plan was measured costing a third of a
    /// second on the main actor. So a plan that throws part-way leaves the
    /// batches before the failure durable and rolls back only the batch that
    /// failed.
    ///
    /// That is safe because a plan is idempotent — every `MergeAction` names its
    /// target by `contentHash` and states an absolute outcome rather than a
    /// delta — so re-deriving and re-applying after a failure reaches the same
    /// place. It is *not* safe to advance a sync cursor on a throw, since the
    /// tail of the plan never landed.
    func applyRemote(_ actions: [MergeAction]) async throws

    func tombstones(since cursor: Date?) async throws -> [Tombstone]
    func recordTombstone(_ tombstone: Tombstone) async throws

    /// The bytes of one representation, or nil when this store will not hand
    /// them over. Never serves concealed content.
    ///
    /// Nil rather than an error: a peer may ask for a representation this
    /// device once offered and has since evicted, and that is an ordinary
    /// answer rather than a fault. Nil is therefore also the right answer for
    /// concealed content — "this store does not hold them" is what a peer is
    /// entitled to know, and it is indistinguishable from every other nil.
    func payload(for contentHash: String, key: RepresentationKey) async throws -> Data?

    /// Records an item learned from a peer, with whatever payload bytes came
    /// with it.
    func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async throws
}
