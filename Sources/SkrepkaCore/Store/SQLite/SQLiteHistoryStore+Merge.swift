// The receiving half of the Linux store's sync surface. Raw SQLite is the Linux
// engine (D-3) and macOS never resolves the CSQLite target, so this is fenced to
// Linux.
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    extension SQLiteHistoryStore {
        /// Applies a merge plan. **One transaction for the whole plan.**
        ///
        /// The SwiftData store commits per chunk of 100 because that is what bounds
        /// the dirty set SwiftData carries and the work one `save()` has to do.
        /// SQLite has no such pressure: a plan is metadata, the statements are
        /// prepared once, and a single transaction is both faster and a stronger
        /// guarantee — a failure leaves the store exactly as the plan found it,
        /// rather than on a chunk boundary. Re-running is free either way, because
        /// a merge is idempotent.
        ///
        /// No batched lookup either, for the same reason the SwiftData side needs
        /// one: there, 500 actions meant 500 round trips through a `ModelContext`;
        /// here every action is one statement against `clip_by_content_hash`
        /// inside an open transaction, and an insert is visible to a later action
        /// in the same plan because the database says so rather than because a
        /// dictionary was kept in step.
        public func applyRemote(_ actions: [MergeAction]) throws {
            guard !actions.isEmpty else { return }

            // Before the plan, and outside its transaction: a store that only ever
            // receives would otherwise never prune, because the deletion paths that
            // do it are the ones it never takes. `MergeEngine` drops expired records
            // before it plans, so nothing in `actions` is a record this could
            // contradict.
            pruneExpiredTombstones()

            var rejectedConcealed = 0
            try database.transaction {
                for action in actions {
                    try apply(action, rejectedConcealed: &rejectedConcealed)
                }
            }

            if rejectedConcealed > 0 {
                SkrepkaLog.store.error(
                    "Refused \(rejectedConcealed) concealed items offered by a peer; concealed content does not sync."
                )
            }
        }

        /// Records an item learned from a peer, with whatever payload bytes came
        /// with it.
        ///
        /// Writes no tombstone and applies no retention, the same division
        /// ``applyRemote(_:)`` keeps: eviction is a local policy decision and does
        /// not belong on the path that learns something.
        ///
        /// A second offer of content already held is not a no-op: metadata is
        /// eager and payload is lazy (design §7), so `applyRemote`'s `.insert`
        /// writes the row with `bytes` still NULL and the bytes arrive here later,
        /// on a fetch the transport decided to make. This is the only method that
        /// writes them, so returning early would make the lazy half of §7
        /// unimplementable — the row would sit in the picker forever with a
        /// preview and nothing to paste.
        public func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws {
            guard !meta.isConcealed else {
                SkrepkaLog.store.error(
                    "Refused a concealed item offered by a peer; concealed content does not sync."
                )
                return
            }
            try database.transaction {
                guard let held = try clipRow(contentHash: meta.contentHash) else {
                    try insertLearned(meta, payloads: payloads)
                    return
                }
                try fillPayload(of: held.id, from: meta, payloads: payloads)
            }
        }

        /// Writes bytes into representations that have none yet.
        ///
        /// `bytes IS NULL` in the `WHERE` is what makes this safe to call on a row
        /// this machine captured itself: a representation already holding bytes is
        /// never overwritten, so a peer cannot replace local content by offering
        /// the same `contentHash`. Caller owns the transaction.
        private func fillPayload(
            of clipID: UUID,
            from meta: SyncClipMeta,
            payloads: [RepresentationKey: Data]
        ) throws {
            let arrived = SQLiteRepresentationMapping.rows(from: meta, payloads: payloads)
                .filter { $0.bytes != nil }
            guard !arrived.isEmpty else { return }
            let statement = try database.prepare(
                """
                UPDATE clip_representation SET bytes = ?, byte_count = ?
                WHERE clip_id = ? AND "type" = ? AND bytes IS NULL
                """
            )
            for row in arrived {
                try statement.bind([
                    .value(row.bytes), .value(row.byteCount), .value(clipID), .value(row.type),
                ])
                try statement.run()
            }
        }

        // MARK: - Actions

        private func apply(_ action: MergeAction, rejectedConcealed: inout Int) throws {
            switch action {
            case .insert(let meta):
                try insert(meta, rejectedConcealed: &rejectedConcealed)
            case .bumpCreatedAt(let contentHash, let date):
                try bumpCreatedAt(contentHash: contentHash, to: date)
            case .applyPin(let contentHash, let register):
                try applyPin(contentHash: contentHash, register: register)
            case .deleteLocally(let contentHash):
                try deleteLocally(contentHash: contentHash)
            case .recordTombstone(let tombstone):
                try upsertTombstone(tombstone)
            case .dropTombstone(let contentHash):
                try dropTombstone(contentHash: contentHash)
            }
        }

        /// Stores content learned from a peer.
        ///
        /// **The concealed check is load-bearing, not defence in depth.**
        /// `MergeEngine.plan` merges what it is given and will emit `.insert` for
        /// metadata a hostile or buggy peer marked concealed — it has no store to
        /// consult and no policy to apply. D-7 says concealed content does not
        /// cross the wire in v1, and this is the only place that can enforce the
        /// receiving half of that. Dropping is the whole action: storing the row
        /// and hiding it would put a peer's password on this disk, which is the
        /// exact outcome the rule exists to prevent.
        ///
        /// The other four actions are not filtered. They name content by hash and
        /// carry none, so the worst a peer can do with one is re-pin or delete
        /// something this machine already holds.
        private func insert(_ meta: SyncClipMeta, rejectedConcealed: inout Int) throws {
            guard !meta.isConcealed else {
                rejectedConcealed += 1
                return
            }
            // Identity is contentHash, never id. Also what makes a replayed plan a
            // no-op the second time.
            guard try clipRow(contentHash: meta.contentHash) == nil else { return }
            try insertLearned(meta, payloads: [:])
        }

        /// A repeat copy on a peer moved the item up.
        ///
        /// Guarded by `created_at < ?` rather than `<> ?`: `createdAt` merges by
        /// max, so a plan applied twice, or two plans arriving out of order, cannot
        /// move a row backwards.
        private func bumpCreatedAt(contentHash: String, to date: Date) throws {
            try database.run(
                "UPDATE clip SET created_at = ? WHERE content_hash = ? AND created_at < ?",
                [.value(date), .value(contentHash), .value(date)]
            )
        }

        /// Adopts the merged pin register wholesale — value, timestamp and author.
        ///
        /// Writing only `is_pinned` would leave the local register stamped with the
        /// old time and device, so the next merge would compute the same action
        /// again and the pin would never converge.
        private func applyPin(contentHash: String, register: LWWRegister<Bool>) throws {
            try database.run(
                """
                UPDATE clip SET is_pinned = ?, pinned_at = ?, pinned_by = ? WHERE content_hash = ?
                """,
                [
                    .value(register.value),
                    .value(register.timestamp),
                    .value(register.deviceID.hex),
                    .value(contentHash),
                ]
            )
        }

        /// Removes content a live tombstone covers, and its payload with it —
        /// `clip_representation` cascades.
        ///
        /// Writes no tombstone of its own. The plan carries `.recordTombstone`
        /// separately when one is needed, and writing a second one here would
        /// restamp somebody else's deletion with this device's clock and identity.
        private func deleteLocally(contentHash: String) throws {
            try database.run("DELETE FROM clip WHERE content_hash = ?", [.value(contentHash)])
        }

        /// Removes a tombstone whose retention window has passed.
        ///
        /// `MergeEngine` decided that against ``MergeInput/now``, so this applies
        /// the verdict rather than recomputing it: a `WHERE deleted_at <= ?` here
        /// would be a second expiry rule written in SQL, the exact drift
        /// ``TombstoneExpiry`` exists to foreclose.
        ///
        /// Opens no transaction — ``applyRemote(_:)`` already holds one for the
        /// whole plan, and a tombstone dropped outside it could survive a plan that
        /// then rolled back.
        private func dropTombstone(contentHash: String) throws {
            try database.run("DELETE FROM tombstone WHERE content_hash = ?", [.value(contentHash)])
        }

        /// Writes the clip row and its representation index for content this store
        /// did not have.
        ///
        /// The index is written even when no bytes came with it. An empty one would
        /// be a claim that the item can serve nothing, so a peer would never fetch
        /// it and the row would sync as a permanent ghost — the same trap
        /// `HistoryStore+Sync`'s backfill exists to get out of.
        private func insertLearned(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws {
            try insert(
                SQLiteClipRow.make(from: meta),
                representations: SQLiteRepresentationMapping.rows(from: meta, payloads: payloads)
            )
        }
    }

#endif
