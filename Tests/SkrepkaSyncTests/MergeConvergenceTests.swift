import Foundation
import Testing

@testable import SkrepkaSync

/// Convergence, asserted as the property rather than as one scenario.
///
/// The model is a grow-only set plus two last-writer-wins registers, and the one
/// claim that matters about it is that peers gossiping in any order end up
/// holding the same thing. Merging two hand-written peers into one replica twice
/// does not say that. It says the replica is insensitive to the order its inbox
/// arrived in — and a bug where two peers apply *different* plans and reach
/// *different* states passes it untouched, because only one of the three ever
/// merges anything. A tombstone rule that consults the local `createdAt` instead
/// of the merged one is exactly that shape, so the property is asserted here
/// between replicas that all actually merge, over every order they can do it in.
@Suite("Merge convergence")
struct MergeConvergenceTests {
    private let now = SyncFixtures.time(1000)

    /// Every order three replicas can gossip in. Six is the whole space, so
    /// there is no sampling to argue about.
    private static let orders: [[Int]] = [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ]

    /// A runaway guard rather than a schedule: reaching it is the failure, not
    /// the answer. Three replicas settle in two rounds.
    private static let roundLimit = 8

    /// Three replicas that disagree about every rule in the model at once.
    ///
    /// - `aa`: a repeat copy on the second replica, which merges by maximum.
    /// - `bb`: pinned on the first, unpinned later by another device on the
    ///   third.
    /// - `cc`: held by the second, deleted afterwards by the third.
    /// - `dd`: content only the third has ever seen.
    /// - `ee`: deleted on the first, then copied again later and held by the
    ///   third — the case a tombstone must not suppress.
    /// - `ff`: deleted on the second at an instant after the first replica's
    ///   copy and before the second's own. Deciding suppression from the local
    ///   `createdAt` alone makes the two replicas disagree about whether it
    ///   survives, which is the divergence this suite exists to catch.
    /// - `gg`: a tombstone on the first, long past its retention window.
    ///
    /// One description per content hash, differing only in the fields the model
    /// merges. `.insert` copies a peer's description wholesale while
    /// `.bumpCreatedAt` leaves the local one in place, so two replicas that
    /// started from different `preview` or `originDeviceID` values for one hash
    /// would still hold different ones at the end — a gap in the model rather
    /// than in the gossip, and not the one under test here.
    private func replicas() -> [MergeReplica] {
        [
            MergeReplica(
                items: [
                    SyncFixtures.meta("aa", createdAt: 10),
                    SyncFixtures.meta("bb", createdAt: 20, pinned: SyncFixtures.pin(true, at: 5)),
                    SyncFixtures.meta("ff", createdAt: 20),
                ],
                tombstones: [
                    SyncFixtures.tombstone("ee", deletedAt: 40),
                    SyncFixtures.tombstone("gg", deletedAt: -SyncLimits.tombstoneRetention),
                ]
            ),
            MergeReplica(
                items: [
                    SyncFixtures.meta("aa", createdAt: 40),
                    SyncFixtures.meta("cc", createdAt: 15, origin: SyncFixtures.deviceB),
                    SyncFixtures.meta("ff", createdAt: 60),
                ],
                tombstones: [SyncFixtures.tombstone("ff", deletedAt: 40, by: SyncFixtures.deviceB)]
            ),
            MergeReplica(
                items: [
                    SyncFixtures.meta(
                        "bb",
                        createdAt: 20,
                        pinned: SyncFixtures.pin(false, at: 9, by: SyncFixtures.deviceB)
                    ),
                    SyncFixtures.meta("dd", createdAt: 60, origin: SyncFixtures.deviceB),
                    SyncFixtures.meta("ee", createdAt: 80),
                ],
                tombstones: [SyncFixtures.tombstone("cc", deletedAt: 50)]
            ),
        ]
    }

    @Test("Every gossip order settles on one shared state")
    func gossipConvergesInEveryOrder() {
        let initial = replicas()
        var settled: [MergeReplica] = []

        for order in Self.orders {
            var live = initial
            #expect(gossipToQuiescence(&live, order: order) != nil, "gossip never settled")
            for replica in live { #expect(replica == live[0]) }
            settled.append(live[0])
            // Every replica was changed by the others, so a model that merged
            // nothing at all cannot pass this by standing still.
            for index in initial.indices { #expect(live[index] != initial[index]) }
        }

        // And every order reached the *same* state, not merely an internally
        // consistent one of its own.
        for state in settled { #expect(state == settled[0]) }
    }

    /// What they settled *on*, so the suite cannot pass by converging on the
    /// wrong thing — an engine that deleted everything converges too.
    @Test("The settled state honours every rule that produced it")
    func settlesOnTheRightState() {
        var live = replicas()
        #expect(gossipToQuiescence(&live, order: Self.orders[0]) != nil)
        let shared = live[0]

        // A repeat copy on one peer moved the item up on all of them.
        #expect(shared.items["aa"]?.createdAt == SyncFixtures.time(40))
        // The later unpin won, by its timestamp rather than by who spoke last.
        #expect(
            shared.items["bb"]?.isPinned
                == SyncFixtures.pin(false, at: 9, by: SyncFixtures.deviceB)
        )
        // Deleted content stays deleted, and the record of it reaches everyone.
        #expect(shared.items["cc"] == nil)
        #expect(shared.tombstones["cc"] == SyncFixtures.tombstone("cc", deletedAt: 50))
        // Content nobody deleted reaches everyone too.
        #expect(shared.items["dd"] != nil)
        // Rule 2: neither copy is content the tombstone predates, so both live.
        #expect(shared.items["ee"]?.createdAt == SyncFixtures.time(80))
        #expect(shared.items["ff"]?.createdAt == SyncFixtures.time(60))
        // The expired record is gone from the store, not merely left unhonoured.
        #expect(shared.tombstones["gg"] == nil)
    }

    // MARK: - Gossip

    /// Gossips until a whole round changes nothing.
    ///
    /// Quiescence rather than a fixed number of rounds: the model is allowed to
    /// need more than one, and counting to a number hides the case that needs
    /// one more than the number.
    ///
    /// - Returns: the round that changed nothing, or `nil` if it never came.
    private func gossipToQuiescence(_ replicas: inout [MergeReplica], order: [Int]) -> Int? {
        var round = 1
        while round <= Self.roundLimit {
            guard gossipRound(&replicas, order: order) else { return round }
            round += 1
        }
        return nil
    }

    /// One pass: every replica merges every other, in `order`.
    ///
    /// - Returns: whether any of those merges produced a non-empty plan.
    private func gossipRound(_ replicas: inout [MergeReplica], order: [Int]) -> Bool {
        var moved = false
        for receiver in order {
            for sender in order where sender != receiver {
                if replicas[receiver].merge(replicas[sender], now: now) { moved = true }
            }
        }
        return moved
    }
}
