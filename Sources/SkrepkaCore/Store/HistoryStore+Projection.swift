// How `items` is kept in step with the database, split from HistoryStore.swift
// so the store there reads as behaviour. Linux has a separate SQLite
// conformance and computes its list on demand instead (D-9).
#if canImport(SwiftData)

    import Foundation
    import SwiftData
    import os

    extension HistoryStore {
        // MARK: - Publishing

        /// Applies what one mutation changed, instead of refetching every row.
        ///
        /// ``items`` is a *projection* of the store, and every mutation already
        /// knows exactly which rows it touched: `capture(_:)` writes one, a pin
        /// flips one, `delete(_:)` removes one, `applyRemote(_:)` carries an
        /// explicit action list and `applyRetention()` an evicted id set. Throwing
        /// that away and rebuilding the whole list was the cost this replaces.
        ///
        /// Measured on Apple silicon, debug and release within noise of each
        /// other, one full ``reload()`` of a store of plain text entries:
        ///
        /// | rows | fetch | map to summaries | hoist | publish | total |
        /// |---|---|---|---|---|---|
        /// | 500 | 7.7 ms | 1.8 ms | 0.14 ms | 0.26 ms | 9.9 ms |
        /// | 5,000 | 74.1 ms | 17.4 ms | 1.3 ms | 0.6 ms | 93.4 ms |
        ///
        /// So four fifths of it is the `FetchDescriptor` round trip — materialising
        /// every `ClipRecord` — and no amount of slimming ``ClipSummary`` touches
        /// that. The only way past it is not to do it, which is this: a `capture()`
        /// against a 5,000-item store went from 106 ms to 3.7 ms, and one against a
        /// 500-item store from 11.4 ms to 0.7 ms.
        ///
        /// Thumbnails were a second, separate cost on the same path, and they are
        /// dealt with by ``thumbnail(for:)`` rather than here: the same rebuild
        /// costs 155 ms with one picture in three and 268 ms when every row is one,
        /// because SwiftData materialises the blob as part of the row rather than
        /// on demand. `FetchDescriptor.propertiesToFetch` excluding `thumbnailData`
        /// was measured and rejected — it cuts the all-pictures fetch from 267 ms
        /// to 126 ms but *raises* the text-only one from 74 ms to 103 ms, and it
        /// cannot answer ``ClipSummary/hasThumbnail`` without faulting the column
        /// back in. Worth revisiting only if launch on a picture-heavy widened
        /// history becomes the complaint.
        ///
        /// - Parameters:
        ///   - upserts: records written or edited, already saved. Order is the
        ///     order they were written, which is how entries sharing a `createdAt`
        ///     are ranked.
        ///   - removals: ids of rows that are gone.
        func project(upserts: [ClipRecord] = [], removals: Set<UUID> = []) {
            publish(
                projection.applying(
                    upserts: upserts.map(ClipRecordMapping.summary(from:)),
                    removals: removals
                )
            )
        }

        /// Rebuilds the list from the store.
        ///
        /// The cost above, so this is for the two moments that have no delta to
        /// apply: launch, and recovery after a `rollback()` has put the context
        /// somewhere the projection cannot describe.
        func reload() {
            do {
                publish(ClipProjection(ordered: try fetchOrdered()))
            } catch {
                SkrepkaLog.store.error("Failed to load history: \(error.localizedDescription)")
                publish(.empty)
            }
        }

        private func publish(_ projection: ClipProjection) {
            self.projection = projection
            verifyProjection()
        }

        /// Every row in store order: newest first, ties in insertion order.
        ///
        /// The tie-break is SwiftData's own and undocumented — measured as
        /// insertion order, which is what `SQLiteHistoryStore` spells `rowid ASC`
        /// and what ``ClipProjection`` reproduces when it applies a delta.
        /// `HistoryStoringTests.orderingIsTheSameOnEveryRead` is the assertion
        /// that the framework has not changed its mind.
        private func fetchOrdered() throws -> [ClipSummary] {
            let descriptor = FetchDescriptor<ClipRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            return try context.fetch(descriptor).map(ClipRecordMapping.summary(from:))
        }

        // MARK: - Thumbnails

        /// The stored preview for one entry, or nil when it has none.
        ///
        /// Read when a row draws rather than carried on ``ClipSummary``: the store
        /// holds one summary per entry the retention cap allows and the picker
        /// draws about twenty of them, so publishing every thumbnail meant reading
        /// — and then keeping resident — every picture in the history. At 5,000
        /// entries each holding a 24 KB preview that is 120 MB and 172 ms of extra
        /// rebuild, for pictures nobody is looking at.
        ///
        /// Callers ask only when ``ClipSummary/hasThumbnail`` says there is one, so
        /// a history of text entries never reaches the store at all.
        public func thumbnail(for id: UUID) -> Data? {
            do {
                return try record(withID: id)?.thumbnailData
            } catch {
                SkrepkaLog.store.error("Failed to load thumbnail: \(error.localizedDescription)")
                return nil
            }
        }

        // MARK: - The invariant

        /// Re-derives the projection from the store and records any disagreement.
        ///
        /// A projection maintained by delta can drift from the database, and the
        /// regression that drift produces is "the list is now wrong" — silent,
        /// and visible to the user long before it is visible to anyone else. This
        /// is what a test asserts instead. Nothing turns it on in the app: a full
        /// rebuild after every mutation is exactly what ``project(upserts:removals:)``
        /// exists to avoid, and running it there would reintroduce the whole cost.
        private func verifyProjection() {
            #if DEBUG
                guard verifiesProjection, projectionDrift == nil else { return }
                do {
                    let rebuilt = try fetchOrdered()
                    guard rebuilt != projection.ordered else { return }
                    projectionDrift = ProjectionDrift(
                        projected: projection.ordered,
                        rebuilt: rebuilt
                    )
                } catch {
                    SkrepkaLog.store.error(
                        "Failed to verify the projection: \(error.localizedDescription)"
                    )
                }
            #endif
        }
    }

    #if DEBUG

        /// A projection that stopped matching the store it projects.
        ///
        /// Both lists, because which one is wrong is the first question and neither
        /// is knowable from the other.
        struct ProjectionDrift: Equatable, Sendable {
            /// What the store published.
            let projected: [ClipSummary]
            /// What a full rebuild says it should have published.
            let rebuilt: [ClipSummary]
        }

    #endif

#endif
