import Foundation
import Testing

@testable import SkrepkaSync

/// The three rules of the merge model, one test each. The convergence property
/// they exist to guarantee is asserted in `MergeConvergenceTests`, over gossip
/// between three replicas rather than over one scenario.
@Suite("Merge engine")
struct MergeEngineTests {
    private let now = SyncFixtures.time(1000)

    private func plan(
        local: [SyncClipMeta] = [],
        localTombstones: [Tombstone] = [],
        remote: [SyncClipMeta] = [],
        remoteTombstones: [Tombstone] = []
    ) -> [MergeAction] {
        MergeEngine.plan(
            MergeInput(
                localItems: local,
                localTombstones: localTombstones,
                remoteItems: remote,
                remoteTombstones: remoteTombstones,
                now: now
            )
        )
    }

    private func hasInsert(_ actions: [MergeAction]) -> Bool {
        actions.contains { action in
            if case .insert = action { return true }
            return false
        }
    }

    private func hasTombstone(_ actions: [MergeAction]) -> Bool {
        actions.contains { action in
            if case .recordTombstone = action { return true }
            return false
        }
    }

    private func hasDeletion(_ actions: [MergeAction]) -> Bool {
        actions.contains { action in
            if case .deleteLocally = action { return true }
            return false
        }
    }

    /// Rule 2, in both arrival orders: the tombstone wins whether the deletion
    /// or the item reached this peer first.
    @Test("A tombstone beats an insert in either arrival order")
    func tombstoneBeatsInsert() {
        let item = SyncFixtures.meta("aa", createdAt: 10)
        let grave = SyncFixtures.tombstone("aa", deletedAt: 20, by: SyncFixtures.deviceB)

        // Deletion first: the peer still offers the item, and it stays gone.
        let deletionFirst = plan(localTombstones: [grave], remote: [item])
        #expect(!hasInsert(deletionFirst))
        #expect(!deletionFirst.contains(.deleteLocally(contentHash: "aa")))

        // Item first: the deletion arrives afterwards and removes it.
        let itemFirst = plan(local: [item], remoteTombstones: [grave])
        #expect(itemFirst.contains(.deleteLocally(contentHash: "aa")))
        #expect(itemFirst.contains(.recordTombstone(grave)))

        // Applied, both orders reach the same place.
        var itemThenDeletion = MergeReplica(items: [item])
        itemThenDeletion.merge(MergeReplica(tombstones: [grave]), now: now)
        var deletionThenItem = MergeReplica(tombstones: [grave])
        deletionThenItem.merge(MergeReplica(items: [item]), now: now)
        #expect(itemThenDeletion == deletionThenItem)
    }

    /// Rule 2 in the direction the suite used to leave untested: `contentHash`
    /// names content rather than a row, so a string copied again after being
    /// deleted arrives carrying the identity the tombstone already names. A
    /// tombstone that compared nothing would delete that fresh clipping on the
    /// next merge with any peer, repeatably, for ninety days.
    @Test("A tombstone suppresses only content it predates")
    func tombstoneSparesLaterContent() {
        let grave = SyncFixtures.tombstone("aa", deletedAt: 20, by: SyncFixtures.deviceB)
        let before = SyncFixtures.meta("aa", createdAt: 10)
        let after = SyncFixtures.meta("aa", createdAt: 30)

        // Held here: older than the deletion goes, newer than it stays.
        #expect(
            plan(local: [before], localTombstones: [grave])
                == [.deleteLocally(contentHash: "aa")]
        )
        #expect(plan(local: [after], localTombstones: [grave]).isEmpty)

        // Offered by the peer: the same verdict, so the two sides agree.
        #expect(plan(localTombstones: [grave], remote: [before]).isEmpty)
        #expect(plan(localTombstones: [grave], remote: [after]) == [.insert(after)])
    }

    /// The boundary, stated rather than left to the reader. At wire precision a
    /// copy made in the same millisecond as the deletion is indistinguishable
    /// from the copy being deleted, and resurrecting content the user asked to
    /// be rid of is the worse of the two mistakes.
    @Test("A deletion stamped at the same instant as the content wins")
    func tombstoneWinsTheSameInstant() {
        let grave = SyncFixtures.tombstone("aa", deletedAt: 20)
        #expect(
            plan(local: [SyncFixtures.meta("aa", createdAt: 20)], localTombstones: [grave])
                == [.deleteLocally(contentHash: "aa")]
        )
    }

    /// The verdict is computed from the *merged* `createdAt`, never the local
    /// one alone. Deciding from the local value would have the peer holding the
    /// newer copy keep it while this one deleted its older copy, and the two
    /// would never converge.
    @Test("A peer's newer copy outlives a deletion this store recorded")
    func mergedCreatedAtDecidesSuppression() {
        #expect(
            plan(
                local: [SyncFixtures.meta("aa", createdAt: 20)],
                localTombstones: [SyncFixtures.tombstone("aa", deletedAt: 40)],
                remote: [SyncFixtures.meta("aa", createdAt: 60)]
            ) == [.bumpCreatedAt(contentHash: "aa", to: SyncFixtures.time(60))]
        )
    }

    /// An expired tombstone stops suppressing the content it named, and is
    /// dropped from the store rather than merely left out of the plan — nothing
    /// else revisits the graveyard on a machine that only ever receives. The
    /// drop names the local store's own record and nobody else's: the peer
    /// clears its copy on its own merge, from its own copy of the timestamps.
    @Test("An expired tombstone is dropped rather than honoured")
    func expiredTombstoneStopsSuppressing() {
        let item = SyncFixtures.meta("aa", createdAt: 10)
        let expired = SyncFixtures.tombstone("aa", deletedAt: 20)
        let afterRetention = expired.deletedAt.addingTimeInterval(
            SyncLimits.tombstoneRetention + 1
        )

        let actions = MergeEngine.plan(
            MergeInput(
                localItems: [],
                localTombstones: [expired],
                remoteItems: [item],
                now: afterRetention
            )
        )
        #expect(actions == [.dropTombstone(contentHash: "aa"), .insert(item)])

        // The peer's expired record is the peer's row to drop, not this one's.
        let theirs = MergeEngine.plan(
            MergeInput(
                localItems: [],
                remoteItems: [],
                remoteTombstones: [expired],
                now: afterRetention
            )
        )
        #expect(theirs.isEmpty)
    }

    /// Rule 3, and the single most important line in the model. Eviction drops
    /// a row and writes no tombstone, so an item absent locally but present on
    /// a peer is re-learned rather than deleted there. A 500-item cap on one
    /// machine must not wipe a peer keeping 5000.
    @Test("An item absent locally is re-inserted, never tombstoned")
    func evictionEmitsNoTombstone() {
        let evicted = SyncFixtures.meta("aa", createdAt: 10)
        let actions = plan(local: [SyncFixtures.meta("bb", createdAt: 20)], remote: [evicted])

        #expect(actions == [.insert(evicted)])
        #expect(!hasTombstone(actions))
        #expect(!hasDeletion(actions))
    }

    /// `createdAt` merges by `max`, so a repeat copy on a peer bumps the row and
    /// neither side can move the other backwards. That makes the field
    /// convergent, not correct: both peers order on the sender's unbounded wall
    /// clock, so a machine an hour fast still wins every comparison until the
    /// skew is spent. Bounding that belongs to the transport — see
    /// ``MergeEngine`` and `docs/linux-sync/open-questions.md`.
    @Test("createdAt takes the maximum, whichever side is ahead")
    func createdAtTakesTheMaximum() {
        let older = SyncFixtures.meta("aa", createdAt: 10)
        let newer = SyncFixtures.meta("aa", createdAt: 90)

        #expect(
            plan(local: [older], remote: [newer])
                == [.bumpCreatedAt(contentHash: "aa", to: newer.createdAt)]
        )
        // The other direction is silent: this peer is already ahead, and the
        // one behind learns from the index it is offered.
        #expect(plan(local: [newer], remote: [older]).isEmpty)
        #expect(plan(local: [older], remote: [older]).isEmpty)
    }

    /// The pin is an ``LWWRegister``, so the same maximum rule applies and the
    /// engine emits an update only when the merge actually changed something.
    @Test("The pin register merges and only changes when it has to")
    func appliesTheMergedPin() {
        let held = SyncFixtures.meta("aa", createdAt: 10, pinned: SyncFixtures.pin(false, at: 1))
        let laterPin = SyncFixtures.pin(true, at: 5, by: SyncFixtures.deviceB)
        let offered = SyncFixtures.meta("aa", createdAt: 10, pinned: laterPin)

        #expect(
            plan(local: [held], remote: [offered])
                == [.applyPin(contentHash: "aa", register: laterPin)]
        )
        // Stale in the other direction: nothing to do.
        #expect(plan(local: [offered], remote: [held]).isEmpty)
    }

    /// Duplicate offers for one content hash must not make the plan depend on
    /// which copy the peer listed last.
    @Test("A peer offering the same content twice folds to one action")
    func foldsDuplicateOffers() {
        let early = SyncFixtures.meta("aa", createdAt: 10)
        let late = SyncFixtures.meta("aa", createdAt: 40)

        let forwards = plan(remote: [early, late])
        let backwards = plan(remote: [late, early])
        #expect(forwards == backwards)
        #expect(forwards.count == 1)
    }

    /// A plan is deterministic down to its ordering, so two peers given the
    /// same inputs produce identical plans rather than merely equivalent ones —
    /// which is what makes them comparable in a test and diffable in a log.
    @Test("The same input produces the same plan every time")
    func plansDeterministically() {
        let local = (0..<20).map { SyncFixtures.meta("local-\($0)", createdAt: Double($0)) }
        let remote = (0..<20).map { SyncFixtures.meta("remote-\($0)", createdAt: Double($0)) }
        let graves = (0..<5).map { SyncFixtures.tombstone("local-\($0)", deletedAt: 500) }

        let first = plan(local: local, remote: remote, remoteTombstones: graves)
        let second = plan(
            local: Array(local.reversed()),
            remote: Array(remote.reversed()),
            remoteTombstones: graves
        )
        #expect(first == second)
    }
}
