import Foundation
import Testing

@testable import SkrepkaCore

/// The ordering rules, without a store.
///
/// `HistoryStoreProjectionTests` is the other half: that the rules asserted here
/// are the ones a re-read of the database gives back.
@Suite("Clip projection")
struct ClipProjectionTests {
    private static func summary(
        _ text: String,
        at offset: TimeInterval,
        pinned: Bool = false,
        id: UUID = UUID()
    ) -> ClipSummary {
        ClipSummary(
            id: id,
            kind: .text,
            text: text,
            sourceBundleID: nil,
            createdAt: Date(timeIntervalSince1970: 900_000 + offset),
            isPinned: pinned,
            isConcealed: false,
            imageSize: nil,
            hasThumbnail: false
        )
    }

    // MARK: - The hoist

    @Test("Pinned entries are hoisted, and each block stays newest first")
    func hoistsPinned() {
        let projection = ClipProjection(ordered: [
            Self.summary("newest", at: 3),
            Self.summary("pinned newer", at: 2, pinned: true),
            Self.summary("older", at: 1),
            Self.summary("pinned older", at: 0, pinned: true),
        ])

        #expect(projection.items.map(\.text) == ["pinned newer", "pinned older", "newest", "older"])
        // The unhoisted list is untouched — it is what a delta is applied to.
        #expect(
            projection.ordered.map(\.text) == ["newest", "pinned newer", "older", "pinned older"]
        )
    }

    // MARK: - Deltas

    @Test("An entry lands at the position its timestamp earns")
    func insertsInOrder() {
        let start = ClipProjection(ordered: [
            Self.summary("third", at: 3),
            Self.summary("first", at: 1),
        ])

        let after = start.applying(upserts: [Self.summary("second", at: 2)])
        #expect(after.ordered.map(\.text) == ["third", "second", "first"])
    }

    @Test("An entry sharing a timestamp lands after the entries it ties with")
    func tiedEntryLandsLast() {
        var projection = ClipProjection.empty
        for text in ["first", "second", "third"] {
            projection = projection.applying(upserts: [Self.summary(text, at: 1)])
        }

        // Insertion order, which is what both engines break a tie by — and what
        // `HistoryStoringTests.orderingIsTheSameOnEveryRead` asserts of them.
        #expect(projection.ordered.map(\.text) == ["first", "second", "third"])
    }

    @Test("Writing an entry that is already listed moves it rather than duplicating it")
    func upsertMoves() {
        let id = UUID()
        let start = ClipProjection(ordered: [
            Self.summary("other", at: 2),
            Self.summary("moved", at: 1, id: id),
        ])

        let after = start.applying(upserts: [Self.summary("moved", at: 3, id: id)])
        #expect(after.ordered.map(\.text) == ["moved", "other"])
    }

    @Test("A pin flip does not move the entry in the unhoisted list")
    func pinDoesNotReorder() {
        let id = UUID()
        let start = ClipProjection(ordered: [
            Self.summary("before", at: 1),
            Self.summary("pinned", at: 1, id: id),
            Self.summary("after", at: 1),
        ])

        let after = start.applying(upserts: [Self.summary("pinned", at: 1, pinned: true, id: id)])
        // The whole reason the unhoisted list is kept: a pin changes no sort key,
        // so re-inserting the row into the hoisted list would have to guess where
        // it belongs among the entries sharing its timestamp.
        #expect(after.ordered.map(\.text) == ["before", "pinned", "after"])
        #expect(after.items.map(\.text) == ["pinned", "before", "after"])
    }

    @Test("Writing the same entry twice in one delta keeps the last write, once")
    func lastWriteWins() {
        let id = UUID()
        let start = ClipProjection(ordered: [Self.summary("other", at: 5)])

        let after = start.applying(upserts: [
            Self.summary("bumped", at: 1, id: id),
            Self.summary("bumped", at: 9, id: id),
        ])
        #expect(after.ordered.map(\.text) == ["bumped", "other"])
        #expect(after.ordered.first?.createdAt == Date(timeIntervalSince1970: 900_009))
    }

    @Test("A removal takes the entry out, and an unknown id changes nothing")
    func removes() {
        let id = UUID()
        let start = ClipProjection(ordered: [
            Self.summary("kept", at: 2),
            Self.summary("doomed", at: 1, id: id),
        ])

        #expect(start.applying(upserts: [], removals: [id]).ordered.map(\.text) == ["kept"])
        #expect(start.applying(upserts: [], removals: [UUID()]) == start)
    }

    @Test("An entry both written and removed in one delta ends up written")
    func writeBeatsRemovalOfTheSameEntry() {
        let id = UUID()
        let start = ClipProjection.empty

        let after = start.applying(upserts: [Self.summary("learned", at: 1, id: id)], removals: [id])
        #expect(after.ordered.map(\.text) == ["learned"])
    }

    @Test("An empty delta is the same projection")
    func emptyDeltaIsIdentity() {
        let start = ClipProjection(ordered: [Self.summary("only", at: 1)])
        #expect(start.applying(upserts: []) == start)
    }
}
