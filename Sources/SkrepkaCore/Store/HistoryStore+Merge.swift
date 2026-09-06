// The receiving half of the sync surface, split from HistoryStore+Sync.swift to
// keep both files under the 300-line ceiling. Linux gets a separate SQLite
// conformance of HistoryStoring in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    /// Every row one chunk of a plan will touch, fetched in two queries instead of
    /// one per action.
    ///
    /// Mutable because the chunk edits it as it goes: an insert has to be visible
    /// to a later action in the same chunk, and a delete has to stop being visible.
    /// SwiftData's own fetches include pending changes, so this only has to
    /// reproduce what a re-fetch would have said.
    private struct MergeLookups {
        var clips: [String: ClipRecord]
        var tombstones: [String: TombstoneRecord]
    }

    /// What a plan changed about the list, gathered as it is applied.
    ///
    /// The plan is the delta, so there is no reason to rediscover it by rebuilding
    /// the projection afterwards — see ``HistoryStore/project(upserts:removals:)``.
    /// Written rather than removed wins when an action touches a row twice, which
    /// is why a written row is dropped from `removals`: the merge can delete
    /// content and then learn it again in the same plan.
    private struct MergeDelta {
        private(set) var written: [ClipRecord] = []
        private(set) var removals: Set<UUID> = []

        mutating func write(_ record: ClipRecord) {
            written.append(record)
            removals.remove(record.id)
        }

        mutating func remove(_ id: UUID) {
            written.removeAll { $0.id == id }
            removals.insert(id)
        }
    }

    extension HistoryStore {
        /// Applies a merge plan. One pair of lookups and one save per chunk, and
        /// the list is edited by the plan's own delta rather than rebuilt.
        ///
        /// Main-actor, deliberately, and measured rather than assumed. A 500-action
        /// plan, Apple silicon, debug and release alike — the cost is SQLite round
        /// trips, not anything the optimiser touches:
        ///
        /// | store | a fetch per action | batched lookups, list rebuilt | batched lookups, list projected |
        /// |---|---|---|---|
        /// | 500 items | — | 70 ms, of which 10 rebuilding | 51 ms |
        /// | 5,000 items | 304 ms | 168 ms, of which 93 rebuilding | 55 ms |
        ///
        /// The merge work itself is ~50 ms in every column and does not grow with
        /// the store, because the lookups are batched per chunk. What grew was the
        /// rebuild — a `FetchDescriptor` over every row, four fifths of it the
        /// round trip — and it is gone: the plan already names what it changed, so
        /// ``HistoryStore/project(upserts:removals:)`` writes that and nothing
        /// else. What is left barely moves between a 500-item store and a 5,000-item
        /// one, which is the property that was missing.
        ///
        /// **That is why this stays on the main actor.** A background
        /// `ModelContext`, or moving the whole store off the main actor, would
        /// relocate the merge work and leave the publishing where it is: the
        /// picker reads ``items`` here whichever context did the writing. Revisit
        /// if a plan ever carries payload bytes.
        public func applyRemote(_ actions: [MergeAction]) throws {
            guard !actions.isEmpty else { return }

            // Before the plan, not after: a store that only ever receives would
            // otherwise never prune, because the deletion paths that do it are the
            // ones it never takes. `MergeEngine` drops expired records before it
            // plans, so nothing in `actions` is a record this could contradict.
            pruneExpiredTombstones()

            var rejectedConcealed = 0
            var delta = MergeDelta()
            do {
                for start in stride(from: 0, to: actions.count, by: Self.syncBatchSize) {
                    let chunk = actions[start..<min(start + Self.syncBatchSize, actions.count)]
                    var lookups = try self.lookups(for: chunk)
                    for action in chunk {
                        try apply(
                            action,
                            into: &lookups,
                            delta: &delta,
                            rejectedConcealed: &rejectedConcealed
                        )
                    }
                    try context.save()
                }
            } catch {
                // A half-applied chunk is not merely lost work: `mainContext` has
                // `autosaveEnabled` on, so the inserts already staged would be
                // committed on the next runloop turn without anything having
                // decided to commit them. Discarding them leaves the store on a
                // chunk boundary, which the next plan can re-derive — a merge is
                // idempotent, so re-running it costs nothing.
                context.rollback()
                reload()
                throw error
            }

            if rejectedConcealed > 0 {
                SkrepkaLog.store.error(
                    "Refused \(rejectedConcealed) concealed items offered by a peer; concealed content does not sync."
                )
            }
            project(upserts: delta.written, removals: delta.removals)
        }

        private func apply(
            _ action: MergeAction,
            into lookups: inout MergeLookups,
            delta: inout MergeDelta,
            rejectedConcealed: inout Int
        ) throws {
            switch action {
            case .insert(let meta):
                try insert(
                    meta,
                    into: &lookups,
                    delta: &delta,
                    rejectedConcealed: &rejectedConcealed
                )
            case .bumpCreatedAt(let contentHash, let date):
                bumpCreatedAt(contentHash: contentHash, to: date, in: lookups, delta: &delta)
            case .applyPin(let contentHash, let register):
                applyPin(contentHash: contentHash, register: register, in: lookups, delta: &delta)
            case .deleteLocally(let contentHash):
                deleteLocally(contentHash: contentHash, in: &lookups, delta: &delta)
            case .recordTombstone(let tombstone):
                upsertTombstone(tombstone, into: &lookups.tombstones)
            case .dropTombstone(let contentHash):
                dropTombstone(contentHash: contentHash, from: &lookups.tombstones)
            }
        }

        // MARK: - Actions

        /// Stores content learned from a peer.
        ///
        /// **The concealed check is load-bearing, not defence in depth.**
        /// `MergeEngine.plan` merges what it is given and will emit `.insert` for
        /// metadata a hostile or buggy peer marked concealed — it has no store to
        /// consult and no policy to apply. D-7 says concealed content does not
        /// cross the wire in v1, and this is the only place that can enforce the
        /// receiving half of that. Dropping is the whole action: storing the row
        /// and hiding it would put a peer's password on this disk, which is the
        /// exact outcome the rule exists to prevent, and the sender is the party
        /// that broke the protocol.
        ///
        /// The other four actions are not filtered. They name content by hash and
        /// carry none, so the worst a peer can do with one is re-pin or delete
        /// something this machine already holds.
        private func insert(
            _ meta: SyncClipMeta,
            into lookups: inout MergeLookups,
            delta: inout MergeDelta,
            rejectedConcealed: inout Int
        ) throws {
            guard !meta.isConcealed else {
                rejectedConcealed += 1
                return
            }
            // Identity is contentHash, never id. Also what makes a replayed plan a
            // no-op the second time.
            guard lookups.clips[meta.contentHash] == nil else { return }
            let record = try SyncMetaMapping.makeRecord(from: meta)
            context.insert(record)
            lookups.clips[meta.contentHash] = record
            delta.write(record)
        }

        /// A repeat copy on a peer moved the item up.
        ///
        /// Guarded by `<` rather than `!=`: `createdAt` merges by max, so a plan
        /// applied twice, or two plans arriving out of order, cannot move a row
        /// backwards.
        private func bumpCreatedAt(
            contentHash: String,
            to date: Date,
            in lookups: MergeLookups,
            delta: inout MergeDelta
        ) {
            guard let record = lookups.clips[contentHash], record.createdAt < date else { return }
            record.createdAt = date
            delta.write(record)
        }

        /// Adopts the merged pin register wholesale — value, timestamp and author.
        ///
        /// Writing only `isPinned` would leave the local register stamped with the
        /// old time and device, so the next merge would compute the same action
        /// again and the pin would never converge.
        private func applyPin(
            contentHash: String,
            register: LWWRegister<Bool>,
            in lookups: MergeLookups,
            delta: inout MergeDelta
        ) {
            guard let record = lookups.clips[contentHash] else { return }
            record.isPinned = register.value
            record.pinnedAt = register.timestamp
            record.pinnedBy = register.deviceID.hex
            delta.write(record)
        }

        /// Removes content a live tombstone covers.
        ///
        /// Writes no tombstone of its own. The plan carries `.recordTombstone`
        /// separately when one is needed, and writing a second one here would
        /// restamp somebody else's deletion with this device's clock and identity.
        private func deleteLocally(
            contentHash: String,
            in lookups: inout MergeLookups,
            delta: inout MergeDelta
        ) {
            guard let record = lookups.clips.removeValue(forKey: contentHash) else { return }
            // Read before the delete: a deleted record is no longer a row to ask.
            let id = record.id
            context.delete(record)
            delta.remove(id)
        }

        /// Removes a tombstone whose retention window has passed.
        ///
        /// `MergeEngine` decided that against ``MergeInput/now``, so this applies
        /// the verdict rather than recomputing it: a second expiry expression here
        /// is exactly the drift ``TombstoneExpiry`` exists to foreclose. Touches no
        /// clip and so no ``MergeDelta`` — dropping the record neither restores the
        /// content it named nor changes anything the picker is reading.
        private func dropTombstone(
            contentHash: String,
            from held: inout [String: TombstoneRecord]
        ) {
            guard let record = held.removeValue(forKey: contentHash) else { return }
            context.delete(record)
        }

        // MARK: - Lookups

        /// Two queries for a whole chunk.
        ///
        /// The alternative — `recordMatching(contentHash:)` per action — is what
        /// made a 500-action plan against a 5,000-item store take 304 ms rather
        /// than 172: 500 SQLite round trips, and the cost is the round trips rather
        /// than the work inside them.
        ///
        /// `#Index` on `contentHash` was tried and dropped: it moved neither number
        /// at 500 or 5,000 rows, and an index is a schema change whose migration
        /// behaviour OQ-9 did not test. Worth revisiting only if a store ever grows
        /// well past its retention cap.
        private func lookups(for chunk: ArraySlice<MergeAction>) throws -> MergeLookups {
            var clipHashes: [String] = []
            var tombstoneHashes: [String] = []
            for action in chunk {
                switch action {
                case .insert(let meta):
                    clipHashes.append(meta.contentHash)
                case .bumpCreatedAt(let contentHash, _), .applyPin(let contentHash, _),
                    .deleteLocally(let contentHash):
                    clipHashes.append(contentHash)
                case .recordTombstone(let tombstone):
                    tombstoneHashes.append(tombstone.contentHash)
                case .dropTombstone(let contentHash):
                    tombstoneHashes.append(contentHash)
                }
            }
            return MergeLookups(
                clips: try clipRecords(matching: clipHashes),
                tombstones: try tombstoneRecords(matching: tombstoneHashes)
            )
        }

        private func clipRecords(matching contentHashes: [String]) throws -> [String: ClipRecord] {
            guard !contentHashes.isEmpty else { return [:] }
            let wanted = contentHashes
            let records = try context.fetch(
                FetchDescriptor<ClipRecord>(predicate: #Predicate { wanted.contains($0.contentHash) })
            )
            // `uniquingKeysWith` rather than a subscript loop so a store that
            // somehow holds two rows for one hash keeps one instead of trapping.
            return Dictionary(records.map { ($0.contentHash, $0) }) { first, _ in first }
        }
    }

#endif
