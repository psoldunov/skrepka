import Foundation

/// The history as the picker reads it, and the rules that order it.
///
/// Two lists, because they answer different questions. ``ordered`` is the
/// history in store order — newest first, entries sharing a `createdAt` in the
/// order the rows were inserted — and it is what a mutation edits. ``items`` is
/// that list with pinned entries hoisted to the top, and it is what the picker
/// draws.
///
/// Keeping both is what makes a delta safe to apply. A pin changes no sort key,
/// so in ``ordered`` the row does not move at all and hoisting afterwards puts
/// it in the right block. Maintaining only the hoisted list would mean guessing
/// where an unpinned row belongs among entries sharing its `createdAt`, and the
/// guess is wrong exactly when two entries were captured in the same instant —
/// which is the case `HistoryStoringTests.orderingIsTheSameOnEveryRead` pins.
///
/// A value type, replaced rather than edited: ``HistoryStore`` publishes
/// ``items`` to SwiftUI, and an assignment is what Observation notices.
struct ClipProjection: Sendable, Equatable {
    /// Newest first, ties in insertion order. What a mutation edits.
    let ordered: [ClipSummary]
    /// ``ordered`` with pinned entries hoisted. What the picker reads.
    let items: [ClipSummary]

    static let empty = ClipProjection(ordered: [])

    init(ordered: [ClipSummary]) {
        self.ordered = ordered
        // A stable partition rather than a sort on `isPinned`: both engines
        // perform this same operation on the same list, so there is one fewer
        // place for them to disagree about what the top of the history is.
        items = ordered.filter(\.isPinned) + ordered.filter { !$0.isPinned }
    }

    /// This projection with `upserts` written and `removals` gone.
    ///
    /// The delta every mutation already knows, instead of refetching and
    /// re-sorting every row to publish a one-row change — the measurement that
    /// motivates it is on ``HistoryStore/reload()``.
    ///
    /// One call covers an insert, a move and an edit in place: an entry already
    /// listed keeps its position unless its `createdAt` changed, and only then is
    /// it removed and re-inserted where the new timestamp puts it.
    ///
    /// **Keeping its position is the load-bearing half.** A pin, a source bundle
    /// identifier and a backfilled thumbnail all leave the sort key alone, and
    /// re-inserting on those would move the row past every entry stamped with the
    /// same instant — which is a store this list no longer describes.
    ///
    /// Naming an entry twice is last-write-wins rather than two rows, because a
    /// merge plan can bump an entry and then pin it. Naming one in both arguments
    /// is a write: the plan learned it after deleting it.
    func applying(upserts: [ClipSummary], removals: Set<UUID> = []) -> ClipProjection {
        guard !upserts.isEmpty || !removals.isEmpty else { return self }

        let written = Self.lastWritePerEntry(upserts)
        let byID = Dictionary(written.map { ($0.id, $0) }) { _, last in last }

        var settled: Set<UUID> = []
        var kept: [ClipSummary] = []
        kept.reserveCapacity(ordered.count)
        for entry in ordered {
            if let update = byID[entry.id] {
                guard update.createdAt == entry.createdAt else { continue }
                kept.append(update)
                settled.insert(entry.id)
            } else if !removals.contains(entry.id) {
                kept.append(entry)
            }
        }

        let moved = written.filter { !settled.contains($0.id) }
        guard !moved.isEmpty else { return ClipProjection(ordered: kept) }
        return ClipProjection(ordered: Self.merging(moved, into: kept))
    }

    /// One entry per id, at the position it was last written.
    private static func lastWritePerEntry(_ upserts: [ClipSummary]) -> [ClipSummary] {
        var seen: Set<UUID> = []
        return upserts.reversed()
            .filter { seen.insert($0.id).inserted }
            .reversed()
    }

    /// Merges entries into a list already in store order.
    ///
    /// An incoming entry lands *after* every entry sharing its `createdAt`,
    /// because that is what insertion order means: the row being written is the
    /// most recently inserted of the ones that tie. `orderingIsTheSameOnEveryRead`
    /// is the assertion that this matches what a re-read of the store says.
    private static func merging(
        _ incoming: [ClipSummary],
        into kept: [ClipSummary]
    ) -> [ClipSummary] {
        var result: [ClipSummary] = []
        result.reserveCapacity(kept.count + incoming.count)

        var index = kept.startIndex
        for entry in newestFirst(incoming) {
            while index < kept.endIndex, kept[index].createdAt >= entry.createdAt {
                result.append(kept[index])
                index += 1
            }
            result.append(entry)
        }
        result.append(contentsOf: kept[index...])
        return result
    }

    /// `Array.sorted(by:)` is not stable, and a plan can carry two entries
    /// stamped with the same instant — so ties are broken by the order they were
    /// handed over, which is the order they were written to the store.
    private static func newestFirst(_ summaries: [ClipSummary]) -> [ClipSummary] {
        summaries.enumerated()
            .sorted { first, second in
                first.element.createdAt == second.element.createdAt
                    ? first.offset < second.offset
                    : first.element.createdAt > second.element.createdAt
            }
            .map(\.element)
    }
}
