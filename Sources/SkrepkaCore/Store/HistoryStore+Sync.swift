// The sync surface of the SwiftData store, kept out of the main file. Linux gets
// a separate SQLite conformance of HistoryStoring in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    // MARK: - Offering

    extension HistoryStore {
        /// How many rows are looked up, applied and saved at a time.
        ///
        /// Bounds three things at once: the dirty set SwiftData carries in one
        /// transaction, the `IN` list each batched lookup builds, and how much work
        /// a single `save()` has to do. Chosen for the last of those — a plan is
        /// metadata, so the batch can be generous without holding much memory.
        static var syncBatchSize: Int { 100 }

        /// Metadata for every syncable item, oldest first.
        ///
        /// Never includes concealed content. **The filter lives here and nowhere
        /// else**: `SkrepkaSync` never sees a payload it was not handed, so the
        /// storage boundary is the only place that can honestly enforce the rule.
        /// It is unconditional — D-7 settled that concealed items do not cross the
        /// wire in v1 and that there is no preference to change that, which is why
        /// this takes no parameter for it.
        ///
        /// **Only representations this device holds bytes for are described**, per
        /// `SyncClipMeta`: a list is a claim about what its owner can serve, so a
        /// row learned from a peer and never fetched is offered promising nothing.
        /// See ``RepresentationIndex/servable(_:holding:)``.
        ///
        /// - Parameter cursor: return only items created strictly after this
        ///   instant. `nil` offers everything. Ordered ascending, so the last
        ///   element's `createdAt` is the caller's next cursor.
        public func syncIndex(since cursor: Date?) throws -> [SyncClipMeta] {
            guard let localDeviceID else { throw HistoryStoreSyncError.deviceIdentityUnavailable }

            var backfilled = 0
            let records = try syncableRecords(since: cursor)
            var metas: [SyncClipMeta] = []
            metas.reserveCapacity(records.count)
            for record in records {
                let representations = servableIndex(of: record, backfilled: &backfilled)
                metas.append(
                    SyncMetaMapping.meta(
                        from: record,
                        representations: representations,
                        localDeviceID: localDeviceID
                    )
                )
            }
            saveBackfill(count: backfilled)
            return metas
        }

        private func syncableRecords(since cursor: Date?) throws -> [ClipRecord] {
            try context.fetch(
                FetchDescriptor<ClipRecord>(
                    predicate: Self.syncablePredicate(since: cursor),
                    sortBy: [SortDescriptor(\.createdAt, order: .forward)]
                )
            )
        }

        /// Written as two `return`s rather than one `if` expression: `#Predicate`
        /// expands to a value pack, which the compiler refuses as an if-expression
        /// branch ("value pack expansion can only appear inside a function argument
        /// list"). Not a style choice.
        private static func syncablePredicate(since cursor: Date?) -> Predicate<ClipRecord> {
            guard let cursor else { return #Predicate { !$0.isConcealed } }
            return #Predicate { !$0.isConcealed && $0.createdAt > cursor }
        }

        /// What the row can serve, and the backfill of a row written before the
        /// index column existed — backfill rather than omission, because the stored
        /// index is what tells a fetch what there is to ask for and a row with none
        /// syncs as a ghost.
        ///
        /// An empty payload short-circuits before any read — a row learned from a
        /// peer and never fetched, which is the case this filter exists for. A row
        /// that does hold bytes costs the decode ``RepresentationIndex`` was written
        /// to avoid; ``RepresentationIndex/servable(_:holding:)`` weighs that. A
        /// payload that will not decode yields an empty index, which for that row is
        /// the truth: there is nothing there to serve.
        private func servableIndex(of record: ClipRecord, backfilled: inout Int) -> [String: Int] {
            guard !record.payloadData.isEmpty else { return [:] }
            do {
                let payload = try ClipRecordMapping.decodePayload(record.payloadData)
                guard let stored = record.representationIndex else {
                    let index = RepresentationIndex.make(from: payload)
                    record.representationIndex = try RepresentationIndex.encode(index)
                    backfilled += 1
                    return index
                }
                let claimed = try RepresentationIndex.decode(stored)
                return RepresentationIndex.servable(claimed, holding: payload)
            } catch {
                SkrepkaLog.store.error(
                    "Failed to read the representation index of an entry: \(error.localizedDescription)"
                )
                return [:]
            }
        }

        /// Persists whatever ``servableIndex(of:backfilled:)`` backfilled.
        ///
        /// A failure here is not a failure of the index: the metadata already
        /// returned is correct, and the only cost is recomputing it next time. So
        /// it is logged rather than thrown, which would fail a sync over a cache
        /// write.
        private func saveBackfill(count: Int) {
            guard count > 0 else { return }
            do {
                try context.save()
            } catch {
                SkrepkaLog.store.error(
                    "Failed to store backfilled representation indexes: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Tombstones

    extension HistoryStore {
        /// Deletions this store has recorded, newest first.
        ///
        /// Expired records are returned too. `MergeEngine` applies
        /// `SyncLimits.tombstoneRetention` against its own `now`, and filtering here
        /// as well would put the expiry rule in two places that can disagree.
        ///
        /// Concealed content is not in here, and is not filtered out on the way
        /// out either: ``recordDeletions(of:)`` writes no tombstone for it in the
        /// first place, which is the only point at which the row is still there to
        /// be consulted.
        ///
        /// - Parameter since: return only deletions recorded strictly after this
        ///   instant. `nil` returns all of them.
        public func tombstones(since: Date?) throws -> [Tombstone] {
            let descriptor = FetchDescriptor<TombstoneRecord>(
                predicate: since.map { cursor in #Predicate { $0.deletedAt > cursor } },
                sortBy: [SortDescriptor(\.deletedAt, order: .reverse)]
            )
            var result: [Tombstone] = []
            for record in try context.fetch(descriptor) {
                guard let tombstone = TombstoneRecordMapping.tombstone(from: record) else {
                    SkrepkaLog.store.error(
                        "Skipping a tombstone whose device identifier is not a 64-character hex string."
                    )
                    continue
                }
                result.append(tombstone)
            }
            return result
        }

        /// Records a deletion, folding it into one this store already holds.
        public func recordTombstone(_ tombstone: Tombstone) throws {
            var held = try tombstoneRecords(matching: [tombstone.contentHash])
            upsertTombstone(tombstone, into: &held)
            try context.save()
        }

        /// Writes a tombstone for each deletion this device just performed that a
        /// peer could act on.
        ///
        /// **Concealed rows get none.** No peer was ever offered that content, so
        /// none of them has anything to delete, and the tombstone would carry the
        /// row's `contentHash` — unsalted, un-stretched SHA-256 over the kind and
        /// the text. Every paired peer keeps that for ninety days, so a password
        /// the user copied and then cleared would leave an offline oracle on
        /// another machine for anyone who later reads its store. That is the risk
        /// class `docs/linux-sync-consideration.md` rules out, and the reason this
        /// takes rows rather than bare hashes: a hash cannot be filtered, because
        /// nothing about it says whose it is.
        ///
        /// Silent when the store has no ``HistoryStore/localDeviceID``: a device
        /// with no sync identity has no peers to tell, and `SyncDeviceID` is derived
        /// from a certificate rather than invented, so there is no placeholder to
        /// write instead. The consequence is worth knowing — deletions made before
        /// pairing leave no tombstone, so a peer that still holds that content
        /// re-offers it on the first sync.
        ///
        /// Does not save. The caller is already inside a transaction that removed
        /// the rows, and the removal and its tombstones have to land together.
        ///
        /// Batched because `clear(keepingPinned:)` can hand this every unpinned row
        /// in the store, and a lookup per hash is what made a 500-action merge take
        /// a third of a second.
        ///
        /// - Parameter deletions: read off the rows *before* they were removed.
        ///   Values rather than `ClipRecord`s so nothing here reads a property of a
        ///   model the caller has already deleted.
        func recordDeletions(of deletions: [(contentHash: String, isConcealed: Bool)]) throws {
            guard let localDeviceID else { return }
            let hashes = deletions.filter { !$0.isConcealed }.map { $0.contentHash }
            guard !hashes.isEmpty else { return }
            let now = Date()
            for start in stride(from: 0, to: hashes.count, by: Self.syncBatchSize) {
                let chunk = hashes[start..<min(start + Self.syncBatchSize, hashes.count)]
                var held = try tombstoneRecords(matching: Array(chunk))
                for contentHash in chunk {
                    upsertTombstone(
                        Tombstone(contentHash: contentHash, deletedAt: now, deviceID: localDeviceID),
                        into: &held
                    )
                }
            }
        }

        /// Inserts a tombstone, or folds it into the one already held for that
        /// content. `Tombstone.merged(with:)` decides, so two peers resolve the same
        /// deletion identically.
        ///
        /// Takes the rows it may fold into rather than fetching them, so a caller
        /// with a batch pays one query for the batch. Does not save.
        func upsertTombstone(_ tombstone: Tombstone, into held: inout [String: TombstoneRecord]) {
            guard let existing = held[tombstone.contentHash] else {
                let record = TombstoneRecordMapping.makeRecord(from: tombstone)
                context.insert(record)
                held[tombstone.contentHash] = record
                return
            }
            // A row whose device identifier will not parse cannot take part in the
            // tie-break, so the incoming record replaces it outright.
            let merged =
                TombstoneRecordMapping.tombstone(from: existing)?.merged(with: tombstone) ?? tombstone
            existing.deletedAt = merged.deletedAt
            existing.deviceIDHex = merged.deviceID.hex
        }

        /// Deletes tombstones `MergeEngine` would no longer honour.
        ///
        /// One row accumulates per deletion and nothing else revisits the table, so
        /// without this the store grows forever and ``tombstones(since:)`` walks
        /// every row it ever wrote.
        ///
        /// **Runs on the deletion paths, never on capture.** `applyRetention()` is
        /// the precedent for housekeeping-on-write, and it is the one method here
        /// that must write no tombstone at all; putting the pruning of tombstones
        /// beside it would leave two kinds of tombstone housekeeping one line apart
        /// with opposite rules. Deletion is where these rows come from, so deletion
        /// is where they are cleared.
        ///
        /// - Parameter now: the instant expiry is measured against, for the same
        ///   reason `MergeInput` carries one — a ninety-day window is untestable
        ///   otherwise.
        func pruneExpiredTombstones(asOf now: Date) throws {
            // A narrowing hint, not the rule: see `TombstoneExpiry`. Ordinarily it
            // selects nothing, which is what keeps this cheap enough to run on
            // every deletion.
            let cutoff = TombstoneExpiry.candidateCutoff(now: now)
            let candidates = try context.fetch(
                FetchDescriptor<TombstoneRecord>(predicate: #Predicate { $0.deletedAt <= cutoff })
            )
            var pruned = 0
            for record in candidates
            where TombstoneExpiry.isExpired(deletedAt: record.deletedAt, at: now) {
                context.delete(record)
                pruned += 1
            }
            guard pruned > 0 else { return }
            try context.save()
        }

        /// ``pruneExpiredTombstones(asOf:)`` against the clock, logged rather than
        /// thrown.
        ///
        /// Housekeeping must not fail the deletion that triggered it: the rows the
        /// user asked to remove are gone and their tombstones are written, and a
        /// table left one generation too large is fixed by the next deletion.
        func pruneExpiredTombstones() {
            do {
                try pruneExpiredTombstones(asOf: Date())
            } catch {
                SkrepkaLog.store.error(
                    "Failed to prune expired tombstones: \(error.localizedDescription)"
                )
            }
        }

        func tombstoneRecords(matching contentHashes: [String]) throws -> [String: TombstoneRecord] {
            guard !contentHashes.isEmpty else { return [:] }
            let wanted = contentHashes
            let records = try context.fetch(
                FetchDescriptor<TombstoneRecord>(
                    predicate: #Predicate { wanted.contains($0.contentHash) }
                )
            )
            // `uniquingKeysWith` rather than a subscript loop so a store that
            // somehow holds two rows for one hash keeps one instead of trapping.
            return Dictionary(records.map { ($0.contentHash, $0) }) { first, _ in first }
        }
    }

#endif
