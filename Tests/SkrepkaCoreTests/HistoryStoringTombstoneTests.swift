import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// Instants either side of the ninety-day retention window.
///
/// Kept out of `EngineFixtures` because only these tests need to name a
/// boundary. `EngineFixtures.epoch` and `SyncLimits.tombstoneRetention` are both
/// whole numbers of seconds, so every instant derived here is exact — the
/// boundary asserted below is a real boundary rather than a floating-point
/// approximation of one.
private enum PruneFixtures {
    /// When the deletion was recorded.
    static let deletedAt = EngineFixtures.at(1)

    /// When the deleted content was copied — before it was deleted, which is the
    /// only ordering a tombstone suppresses. Content copied *after* a deletion is
    /// a fresh clipping and `MergeEngine` deliberately lets it through.
    static let beforeDeletion = deletedAt.addingTimeInterval(-1)

    /// The first instant `Tombstone.isExpired(at:)` answers true — expiry is
    /// `>=`, so the boundary belongs to the expired side.
    static let expiry = deletedAt.addingTimeInterval(SyncLimits.tombstoneRetention)

    /// One millisecond inside the window. The smallest step there is: `Tombstone`
    /// normalises `deletedAt` to millisecond precision, so a finer offset would
    /// round away and the test would assert nothing.
    static let lastMomentHonoured = expiry.addingTimeInterval(-0.001)

    static func tombstone(_ contentHash: String) -> Tombstone {
        Tombstone(
            contentHash: contentHash,
            deletedAt: deletedAt,
            deviceID: EngineFixtures.peerDevice
        )
    }

    /// A deletion recorded on the far side of the window, so a prune measured at
    /// ``expiry`` must leave it alone.
    static func live(_ contentHash: String) -> Tombstone {
        Tombstone(contentHash: contentHash, deletedAt: expiry, deviceID: EngineFixtures.peerDevice)
    }
}

/// The tombstone surface of ``HistoryStoringTests`` — which deletions get one,
/// and how long it survives.
///
/// A tombstone is the only record that a deletion happened, so pruning one even
/// an instant before `MergeEngine` stops honouring it hands a peer that still
/// holds the item permission to offer it back. These run against every engine
/// because the cutoff is the sort of thing two implementations restate slightly
/// differently, and the direction of the error decides whether the feature works
/// or destroys data.
///
/// The same reasoning runs the other way for concealed content, which is why the
/// two questions share a file: the record outlives the row it describes by
/// ninety days on every paired machine, so what it is allowed to carry matters
/// exactly as much as how long it is kept.
extension HistoryStoringTests {
    // MARK: - What earns a tombstone

    /// A peer was never offered concealed content, so it has nothing to delete —
    /// and a tombstone names content by `contentHash`, unsalted SHA-256 over the
    /// kind and the text. Writing one would leave every paired machine holding an
    /// offline oracle for the secret, for ninety days, which
    /// `docs/linux-sync-consideration.md` rules out.
    @Test("Deleting a concealed entry writes no tombstone", arguments: HistoryStoreEngine.all)
    func deletingConcealedContentWritesNoTombstone(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("visible", at: EngineFixtures.at(1))))
        #expect(
            await store.capture(
                EngineFixtures.item("hunter2", concealed: true, at: EngineFixtures.at(2))
            )
        )
        for summary in try await store.summaries() {
            await store.delete(summary.id)
        }

        #expect(try await store.summaries().isEmpty)
        #expect(
            try await store.tombstones(since: nil).map(\.contentHash)
                == [EngineFixtures.contentHash("visible")]
        )
    }

    /// The path a user actually hits: copy a password, then Clear History. It
    /// writes the most tombstones of anything in the store, so it is the one that
    /// would leak the most.
    @Test("Clearing history writes no tombstone for concealed entries", arguments: HistoryStoreEngine.all)
    func clearingWritesNoTombstoneForConcealedContent(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("visible", at: EngineFixtures.at(1))))
        #expect(
            await store.capture(
                EngineFixtures.item("hunter2", concealed: true, at: EngineFixtures.at(2))
            )
        )
        await store.clear(keepingPinned: false)

        #expect(try await store.summaries().isEmpty)
        #expect(
            try await store.tombstones(since: nil).map(\.contentHash)
                == [EngineFixtures.contentHash("visible")]
        )
    }

    // MARK: - Pruning

    @Test("An expired tombstone is pruned and a live one is left", arguments: HistoryStoreEngine.all)
    func expiredTombstonesArePruned(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let expired = PruneFixtures.tombstone("long-gone")
        let live = PruneFixtures.live("recent")
        try await store.recordTombstone(expired)
        try await store.recordTombstone(live)

        try await store.pruneExpiredTombstones(asOf: PruneFixtures.expiry)

        #expect(try await store.tombstones(since: nil) == [live])
    }

    /// The boundary, asserted against `Tombstone.isExpired(at:)` itself rather
    /// than against a restatement of it. Two spellings of one boundary is the bug
    /// this guards: a prune a millisecond early is silent data loss, and a prune
    /// a millisecond late costs one row.
    @Test("A tombstone one millisecond inside the window is not pruned", arguments: HistoryStoreEngine.all)
    func theBoundaryIsTheMergeEnginesBoundary(engine: HistoryStoreEngine) async throws {
        let tombstone = PruneFixtures.tombstone("abc")
        #expect(!tombstone.isExpired(at: PruneFixtures.lastMomentHonoured))
        #expect(tombstone.isExpired(at: PruneFixtures.expiry))

        let store = try await Self.makeStore(engine)
        try await store.recordTombstone(tombstone)

        try await store.pruneExpiredTombstones(asOf: PruneFixtures.lastMomentHonoured)
        #expect(try await store.tombstones(since: nil) == [tombstone])

        try await store.pruneExpiredTombstones(asOf: PruneFixtures.expiry)
        #expect(try await store.tombstones(since: nil).isEmpty)
    }

    @Test("Pruning leaves history and live tombstones alone", arguments: HistoryStoreEngine.all)
    func pruningLeavesLiveRowsAlone(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("kept", at: EngineFixtures.at(1))))
        let live = PruneFixtures.live("recent")
        try await store.recordTombstone(live)

        try await store.pruneExpiredTombstones(asOf: PruneFixtures.expiry)

        // A prune reaches the tombstone table and nothing else. The entry is older
        // than the window by ninety days and stays anyway: how long an *item*
        // lives is `RetentionPolicy`'s decision, and confusing the two windows
        // would empty the history every time somebody deleted a clip.
        #expect(try await store.summaries().map(\.text) == ["kept"])
        #expect(try await store.tombstones(since: nil) == [live])
    }

    /// What the whole feature is for: the store stops protecting content at the
    /// same instant the merge engine stops honouring the record, and not before.
    @Test(
        "A tombstone stops protecting content exactly when the merge engine lets go",
        arguments: HistoryStoreEngine.all
    )
    func pruningAndTheMergeEngineLetGoTogether(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        // Older than the deletion, and that is load-bearing rather than
        // incidental: a tombstone only suppresses content it predates, so an
        // offer stamped *after* the deletion is a re-copy and is meant to
        // survive. Resurrection — the thing this test guards — is a peer
        // handing back the very clipping that was deleted, which is this one.
        let offer = EngineFixtures.meta("gone", at: PruneFixtures.beforeDeletion)
        let tombstone = PruneFixtures.tombstone(offer.contentHash)
        try await store.recordTombstone(tombstone)

        // One millisecond inside the window. Both halves matter: a prune here
        // would delete the only record of the deletion, and this very offer would
        // then put the content straight back.
        try await store.pruneExpiredTombstones(asOf: PruneFixtures.lastMomentHonoured)
        let held = try await store.tombstones(since: nil)
        #expect(held == [tombstone])
        #expect(Self.plan(offering: offer, against: held, at: PruneFixtures.lastMomentHonoured).isEmpty)

        // At the boundary both let go. Re-learning the content is now ordinary
        // rather than a resurrection — nothing on either side still claims the
        // deletion happened.
        try await store.pruneExpiredTombstones(asOf: PruneFixtures.expiry)
        let dropped = try await store.tombstones(since: nil)
        #expect(dropped.isEmpty)

        let plan = Self.plan(offering: offer, against: dropped, at: PruneFixtures.expiry)
        #expect(plan == [.insert(offer)])
        try await store.applyRemote(plan)
        #expect(try await store.summaries().map(\.text) == ["gone"])
    }

    /// What a peer offering `offer` would have this store do, given the tombstones
    /// it still holds. An empty history, so the only thing the plan can turn on is
    /// whether the deletion is still on record.
    private static func plan(
        offering offer: SyncClipMeta,
        against tombstones: [Tombstone],
        at now: Date
    ) -> [MergeAction] {
        MergeEngine.plan(
            MergeInput(
                localItems: [],
                localTombstones: tombstones,
                remoteItems: [offer],
                now: now
            )
        )
    }
}
