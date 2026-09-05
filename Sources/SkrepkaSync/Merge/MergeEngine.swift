import Foundation

/// Turns one local state and one peer's offer into a list of ``MergeAction``.
///
/// Pure and synchronous: no clock, no storage, no network — the same shape as
/// `CaptureRules.decide` and `RetentionPolicy.idsToEvict`, which is exactly why
/// those two are testable today.
///
/// The model is a **grow-only set plus two last-writer-wins registers**, not a
/// general CRDT. That works because `ClipItem` is immutable except for
/// `isPinned`, `createdAt` and deletion. **Adding a mutable field to `ClipItem`
/// is what breaks this phase's assumptions** — it would need either a third
/// register or a real CRDT, and a field merged by neither would silently
/// converge to whichever peer spoke last.
///
/// Three rules:
///
/// 1. **Identity is `contentHash`, never `id`.** Two machines copying the same
///    string must converge, and a locally generated `UUID` cannot.
/// 2. **A tombstone beats content it predates**, in either arrival order,
///    until it expires — and only content it predates. `contentHash` names
///    content rather than a row, so a string the user copies again after
///    deleting it arrives carrying the identity the tombstone already names. A
///    rule that compared nothing would delete that fresh clipping on the next
///    merge with any peer, repeatably, for the whole retention window. The
///    comparison is against the *merged* `createdAt`, so both peers reach the
///    same verdict from the same pair of timestamps.
/// 3. **Retention is not deletion.** The engine never emits
///    ``MergeAction/recordTombstone(_:)`` for an item merely absent locally.
///    Absence means "evicted here", and re-learning an evicted clip from a peer
///    is correct — the local cap simply re-evicts it. A 500-item cap on one
///    machine must not wipe a peer keeping 5000, and conflating the two verbs
///    is how a sync feature quietly destroys history.
public enum MergeEngine {
    /// The plan, in a deterministic order.
    ///
    /// Ordering is by action group and then by `contentHash`, so two peers
    /// given the same inputs produce not merely equivalent plans but identical
    /// ones. Nothing downstream depends on the order — the actions commute —
    /// but a plan that is stable is a plan that can be compared in a test and
    /// diffed in a log.
    public static func plan(_ input: MergeInput) -> [MergeAction] {
        let merged = mergedTombstones(input)
        let live = merged.filter { !$0.value.isExpired(at: input.now) }
        let localItems = index(input.localItems)
        let remoteItems = index(input.remoteItems)

        return newTombstones(input, merged: live)
            + expiredDrops(input, merged: merged)
            + itemActions(local: localItems, remote: remoteItems, tombstones: live)
    }

    // MARK: - Tombstones

    /// Folds both sides' tombstones by content, expired records included.
    ///
    /// Expiry is applied to the *merged* record rather than to each side's, so
    /// a peer holding a later deletion for the same content keeps it alive —
    /// which is the conservative direction, since erring the other way brings
    /// back content the user deleted. ``plan(_:)`` splits the result in two: the
    /// live records are the ones the plan honours, and the expired ones the
    /// local store still holds are what ``expiredDrops(_:merged:)`` clears.
    private static func mergedTombstones(_ input: MergeInput) -> [String: Tombstone] {
        var merged: [String: Tombstone] = [:]
        for tombstone in input.localTombstones + input.remoteTombstones {
            merged[tombstone.contentHash] =
                merged[tombstone.contentHash]?.merged(with: tombstone) ?? tombstone
        }
        return merged
    }

    /// Tombstones the local store does not hold, or holds an older version of.
    private static func newTombstones(
        _ input: MergeInput,
        merged: [String: Tombstone]
    ) -> [MergeAction] {
        let local = index(input.localTombstones, by: \.contentHash) { $0.merged(with: $1) }
        return merged.values
            .filter { local[$0.contentHash] != $0 }
            .sorted { $0.contentHash < $1.contentHash }
            .map { MergeAction.recordTombstone($0) }
    }

    /// Tombstones this store holds whose retention window has passed.
    ///
    /// Emitted only for records the local store actually holds: a peer's
    /// expired record is the peer's row to drop, and it will drop it on its own
    /// merge from its own copy of the same timestamps. ``MergeInput/now`` is the
    /// only clock the model has, which makes this the one place that can call a
    /// record expired without writing a second expiry rule beside
    /// ``Tombstone/isExpired(at:)``.
    private static func expiredDrops(
        _ input: MergeInput,
        merged: [String: Tombstone]
    ) -> [MergeAction] {
        let held = Set(input.localTombstones.map(\.contentHash))
        return
            merged
            .filter { held.contains($0.key) && $0.value.isExpired(at: input.now) }
            .keys
            .sorted()
            .map { MergeAction.dropTombstone(contentHash: $0) }
    }

    // MARK: - Items

    /// One pass over the union of both sides' items, emitting at most one
    /// deletion, one insert, or one pair of updates for each.
    private static func itemActions(
        local: [String: SyncClipMeta],
        remote: [String: SyncClipMeta],
        tombstones: [String: Tombstone]
    ) -> [MergeAction] {
        var deletions: [MergeAction] = []
        var inserts: [MergeAction] = []
        var updates: [MergeAction] = []

        for hash in Set(local.keys).union(remote.keys).sorted() {
            let held = local[hash]
            // Rule 2, in either arrival order: a live tombstone beats content
            // it predates, and loses to content created after it.
            guard !suppresses(tombstones[hash], held: held, offered: remote[hash]) else {
                if held != nil { deletions.append(.deleteLocally(contentHash: hash)) }
                continue
            }
            guard let offered = remote[hash] else { continue }
            guard let held else {
                // Rule 3: absent locally means evicted here, not deleted
                // anywhere. Re-learning it is correct, and no tombstone is
                // written.
                inserts.append(.insert(offered))
                continue
            }
            updates += fieldUpdates(contentHash: hash, held: held, offered: offered)
        }
        return deletions + inserts + updates
    }

    /// Whether a tombstone covers this content on both peers alike.
    ///
    /// The comparison is against the **merged** `createdAt` — the later of what
    /// the two sides hold — never against the local one alone. Deciding from
    /// the local value would have the peer holding the newer copy keep it while
    /// the other deleted its older one, and the two would never converge; both
    /// peers see the same pair of descriptions, so both reach the same verdict.
    ///
    /// The boundary is `>=`, so a deletion stamped at the same instant as the
    /// content wins. Wire timestamps are millisecond-precision, which makes
    /// "copied again within the same millisecond as the deletion"
    /// indistinguishable from "deleted the copy just made"; erring towards the
    /// tombstone costs a re-copy the user can simply repeat, and erring the
    /// other way resurrects content they asked to be rid of.
    ///
    /// Answers `false` when neither side describes the content, which cannot
    /// happen for a hash drawn from the union of the two key sets.
    private static func suppresses(
        _ tombstone: Tombstone?,
        held: SyncClipMeta?,
        offered: SyncClipMeta?
    ) -> Bool {
        guard let tombstone, let newest = later(held?.createdAt, offered?.createdAt) else {
            return false
        }
        return tombstone.deletedAt >= newest
    }

    /// The later of two instants, either of which may be absent.
    private static func later(_ first: Date?, _ second: Date?) -> Date? {
        guard let first else { return second }
        guard let second else { return first }
        return max(first, second)
    }

    /// The two fields two peers may legitimately disagree about, merged.
    ///
    /// `createdAt` takes the maximum, so a repeat copy on the peer bumps the row
    /// and neither side can move the other backwards. That makes the field
    /// *convergent*; it does not make it correct. Both this and
    /// ``LWWRegister/merged(with:)`` order on the sender's wall clock, unbounded
    /// and never restamped by the receiver, so a peer whose clock is an hour
    /// fast writes values that outrank every honest one until the skew is spent
    /// — a pin from the fast machine beats each later unpin from the slow one.
    /// The bound lives in the transport, which has a second clock to compare
    /// against where a pure function has none: `InboundClock` refuses metadata
    /// stamped more than `SyncLimits.maximumClockSkew` ahead of the receiver
    /// before it ever reaches this function. So what arrives here is already
    /// bounded, and this rule stays a plain maximum over what it is given. See
    /// `docs/linux-sync/open-questions.md` on preferring the receiver's clock
    /// for anything stored and treating a sender's timestamp as data to order
    /// by rather than as truth.
    private static func fieldUpdates(
        contentHash: String,
        held: SyncClipMeta,
        offered: SyncClipMeta
    ) -> [MergeAction] {
        var updates: [MergeAction] = []
        if offered.createdAt > held.createdAt {
            updates.append(.bumpCreatedAt(contentHash: contentHash, to: offered.createdAt))
        }
        let pin = held.isPinned.merged(with: offered.isPinned)
        if pin != held.isPinned {
            updates.append(.applyPin(contentHash: contentHash, register: pin))
        }
        return updates
    }

    // MARK: - Indexing

    /// Folds items by content hash, so a peer offering the same content twice
    /// in one batch cannot make the plan depend on which copy came last.
    /// ``SyncClipMeta/combining(_:)`` is commutative, so the fold order is
    /// irrelevant rather than merely conventional.
    private static func index(_ items: [SyncClipMeta]) -> [String: SyncClipMeta] {
        index(items, by: \.contentHash) { $0.combining($1) }
    }

    private static func index<Element>(
        _ elements: [Element],
        by key: KeyPath<Element, String>,
        merging combine: (Element, Element) -> Element
    ) -> [String: Element] {
        var result: [String: Element] = [:]
        for element in elements {
            let hash = element[keyPath: key]
            result[hash] = result[hash].map { combine($0, element) } ?? element
        }
        return result
    }
}
