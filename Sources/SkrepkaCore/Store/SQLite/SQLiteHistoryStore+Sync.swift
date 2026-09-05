// The offering half of the Linux store's sync surface. Raw SQLite is the Linux
// engine (D-3) and macOS never resolves the CSQLite target, so this is fenced to
// Linux.
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    // MARK: - Offering

    extension SQLiteHistoryStore {
        /// The representations this device can actually serve, for the query that
        /// joins `clip_representation` in as `r`.
        ///
        /// `IS NOT NULL` rather than a length test, and the column is never
        /// selected: NULL-ness is in the record header, so SQLite answers this
        /// without reading a byte of the blob. That is what keeps
        /// ``syncIndex(since:)`` the metadata-only query
        /// ``HistorySchema/representationTable`` splits the table to make it — see
        /// `SQLiteHistoryStoreTests.aMaximumSizedPayloadRoundTrips`. Computed
        /// rather than stored, for the reason `HistoryStore.syncBatchSize` is.
        static var locallyServable: ClipFilter { ClipFilter(condition: "r.bytes IS NOT NULL") }

        /// Metadata for every syncable item, oldest first.
        ///
        /// Never includes concealed content. **The filter lives here and nowhere
        /// else**: `SkrepkaSync` never sees a payload it was not handed, so the
        /// storage boundary is the only place that can honestly enforce the rule.
        /// It is unconditional — D-7 settled that concealed items do not cross the
        /// wire in v1 and that there is no preference to change that, which is why
        /// this takes no parameter for it.
        ///
        /// There is no backfill step, and no `representationIndex` column for one
        /// to repair: byte counts live in `clip_representation` beside the bytes
        /// they describe, written in the same statement, so the two cannot fall out
        /// of step. That is the one place the two engines' *shapes* differ rather
        /// than their behaviour — see ``HistorySchema/representationTable``.
        ///
        /// **Only representations this device holds bytes for are described.**
        /// `SyncClipMeta.representations` is a claim about what its owner can
        /// serve, so a row learned from a peer and never fetched — `byte_count`
        /// set, `bytes` `NULL` — is offered with none. Advertising those would
        /// promise bytes this device does not have: Mac A holds an item as text and
        /// PDF, Linux B learns it and fetches only the text, and B's next offer to
        /// Mac C promises a PDF that C asks for and B cannot send. The row is still
        /// offered, since its metadata is worth merging; it simply promises
        /// nothing, which is what ``payload(for:key:)`` already answers for it.
        ///
        /// - Parameter cursor: return only items created strictly after this
        ///   instant. `nil` offers everything. Ordered ascending, so the last
        ///   element's `createdAt` is the caller's next cursor.
        public func syncIndex(since cursor: Date?) throws -> [SyncClipMeta] {
            guard let localDeviceID else { throw HistoryStoreSyncError.deviceIdentityUnavailable }

            let rows = try clipRows(
                .syncable(since: cursor),
                trailing: "ORDER BY created_at ASC, rowid ASC"
            )
            // The same filter, qualified for the query that joins — so the index
            // offer and the rows it describes cannot disagree about what is in it.
            let indexes = try representationIndexes(
                .syncable(since: cursor, qualifier: "c.").and(Self.locallyServable)
            )
            return rows.map { row in
                SQLiteClipMapping.meta(
                    from: row,
                    representations: indexes[row.id] ?? [:],
                    localDeviceID: localDeviceID
                )
            }
        }

        /// The bytes of one representation, or nil when this store will not hand
        /// them over.
        ///
        /// Nil rather than an error, per `HistoryStoring`: a peer may ask for a
        /// representation this device once offered and has since evicted, and that
        /// is an ordinary answer rather than a fault. So is a row learned from a
        /// peer whose payload has never been fetched — its `bytes` column is
        /// `NULL` while its `byte_count` is not.
        ///
        /// So is a concealed entry, which is why the lookup is scoped by
        /// ``ClipFilter/syncable(since:qualifier:)`` rather than by hash alone —
        /// the same rule ``syncIndex(since:)`` offers by, deliberately not a second
        /// copy of it. Omitting concealed content from the index is not enough on
        /// its own: `contentHash` is unsalted SHA-256 over the kind and the text,
        /// so a peer can name content it was never offered, and answering would
        /// both confirm the guess and return the secret (D-7).
        public func payload(for contentHash: String, key: RepresentationKey) throws -> Data? {
            let filter = ClipFilter.syncable(since: nil).and(.contentHash(contentHash))
            guard let row = try clipRows(filter, trailing: "LIMIT 1").first else { return nil }
            return try representationBytes(
                clipID: row.id,
                types: SQLiteRepresentationMapping.localTypes(for: key)
            )
        }
    }

    // MARK: - Tombstones

    extension SQLiteHistoryStore {
        /// Deletions this store has recorded, newest first.
        ///
        /// Expired records are returned too. `MergeEngine` applies
        /// `SyncLimits.tombstoneRetention` against its own `now`, and filtering here
        /// as well would put the expiry rule in two places that can disagree.
        ///
        /// Concealed content is not in here, and is not filtered out on the way out
        /// either: ``recordDeletions(of:)`` writes no tombstone for it in the first
        /// place, which is the only point at which the row is still there to be
        /// consulted.
        ///
        /// - Parameter cursor: return only deletions recorded strictly after this
        ///   instant. `nil` returns all of them.
        public func tombstones(since cursor: Date?) throws -> [Tombstone] {
            var sql = "SELECT content_hash, deleted_at, device_id FROM tombstone"
            if cursor != nil { sql += " WHERE deleted_at > ?" }
            sql += " ORDER BY deleted_at DESC, rowid ASC"

            var result: [Tombstone] = []
            var skipped = 0
            try database.query(sql, cursor.map { [.value($0)] } ?? []) { statement in
                guard let tombstone = Self.tombstone(from: statement) else {
                    skipped += 1
                    return
                }
                result.append(tombstone)
            }
            if skipped > 0 {
                SkrepkaLog.store.error(
                    "Skipped \(skipped) tombstones whose device identifier is not a 64-character hex string."
                )
            }
            return result
        }

        /// Records a deletion, folding it into one this store already holds.
        public func recordTombstone(_ tombstone: Tombstone) throws {
            try database.transaction { try upsertTombstone(tombstone) }
        }

        /// Writes a tombstone for each deletion this device just performed that a
        /// peer could act on.
        ///
        /// **Concealed rows get none.** No peer was ever offered that content, so
        /// none of them has anything to delete, and the tombstone would carry the
        /// row's `content_hash` — unsalted, un-stretched SHA-256 over the kind and
        /// the text. Every paired peer keeps that for ninety days, so a password
        /// the user copied and then cleared would leave an offline oracle on
        /// another machine for anyone who later reads its store. That is the risk
        /// class `docs/linux-sync-consideration.md` rules out, and the reason this
        /// takes rows rather than bare hashes: a hash cannot be filtered, because
        /// nothing about it says whose it is.
        ///
        /// Silent when the store has no ``SQLiteHistoryStore/localDeviceID``: a
        /// device with no sync identity has no peers to tell, and `SyncDeviceID` is
        /// derived from a certificate rather than invented, so there is no
        /// placeholder to write instead. The consequence is worth knowing —
        /// deletions made before pairing leave no tombstone, so a peer that still
        /// holds that content re-offers it on the first sync.
        ///
        /// Opens no transaction. The caller is already inside one that removed the
        /// rows, and the removal and its tombstones have to land together.
        ///
        /// - Parameter rows: read out of the table *before* the `DELETE`, which is
        ///   what every caller already does — the hashes were never readable
        ///   afterwards either.
        func recordDeletions(of rows: [SQLiteClipRow]) throws {
            guard let localDeviceID else { return }
            let hashes = rows.filter { !$0.isConcealed }.map(\.contentHash)
            guard !hashes.isEmpty else { return }
            let now = Date()
            for contentHash in hashes {
                try upsertTombstone(
                    Tombstone(contentHash: contentHash, deletedAt: now, deviceID: localDeviceID)
                )
            }
        }

        /// Inserts a tombstone, or folds it into the one already held for that
        /// content.
        ///
        /// `Tombstone.merged(with:)` decides — the same function the SwiftData
        /// store calls, rather than an equivalent written in SQL. A row-value
        /// comparison in the `ON CONFLICT` clause would be shorter and would rank
        /// device identifiers by SQLite's `BINARY` collation instead of by
        /// `SyncDeviceID`'s own ordering, so two peers could resolve one deletion
        /// differently and neither would be wrong.
        ///
        /// Opens no transaction; every caller here already holds one.
        func upsertTombstone(_ tombstone: Tombstone) throws {
            let merged = try heldTombstone(contentHash: tombstone.contentHash)?.merged(with: tombstone)
            let winner = merged ?? tombstone
            try database.run(
                """
                INSERT INTO tombstone (content_hash, deleted_at, device_id) VALUES (?, ?, ?)
                ON CONFLICT(content_hash) DO UPDATE SET deleted_at = excluded.deleted_at,
                                                        device_id = excluded.device_id
                """,
                [.value(winner.contentHash), .value(winner.deletedAt), .value(winner.deviceID.hex)]
            )
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
        /// Two statements rather than one `DELETE ... WHERE deleted_at <= ?`: the
        /// cutoff is a narrowing hint and `TombstoneExpiry.isExpired` is the rule,
        /// so a `DELETE` carrying the comparison would be a second expiry rule
        /// written in SQL — the exact drift `TombstoneExpiry` exists to foreclose.
        ///
        /// - Parameter now: the instant expiry is measured against, for the same
        ///   reason `MergeInput` carries one — a ninety-day window is untestable
        ///   otherwise.
        func pruneExpiredTombstones(asOf now: Date) throws {
            // `tombstone_by_deleted_at` makes this a range scan that ordinarily
            // matches nothing, which is what keeps it cheap on every deletion.
            var doomed: [String] = []
            try database.query(
                "SELECT content_hash, deleted_at FROM tombstone WHERE deleted_at <= ?",
                [.value(TombstoneExpiry.candidateCutoff(now: now))]
            ) { statement in
                guard let contentHash = statement.text(0),
                    let deletedAt = statement.date(1),
                    TombstoneExpiry.isExpired(deletedAt: deletedAt, at: now)
                else { return }
                doomed.append(contentHash)
            }
            guard !doomed.isEmpty else { return }
            try database.transaction {
                for contentHash in doomed {
                    try database.run(
                        "DELETE FROM tombstone WHERE content_hash = ?",
                        [.value(contentHash)]
                    )
                }
            }
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

        /// The tombstone already held for this content, if it is one this build can
        /// read.
        ///
        /// A row whose device identifier will not parse cannot take part in the
        /// tie-break, so it reads as absent and the incoming record replaces it
        /// outright — the same resolution `HistoryStore.upsertTombstone` reaches.
        private func heldTombstone(contentHash: String) throws -> Tombstone? {
            var held: Tombstone?
            try database.query(
                "SELECT content_hash, deleted_at, device_id FROM tombstone WHERE content_hash = ?",
                [.value(contentHash)]
            ) { statement in
                held = Self.tombstone(from: statement)
            }
            return held
        }

        /// Reads a row selected as `content_hash, deleted_at, device_id`.
        ///
        /// `nil` when the device identifier is not one — failing rather than
        /// substituting, because a tombstone's device is half of its tie-break and
        /// inventing one would let two peers resolve the same deletion differently.
        private static func tombstone(from statement: SQLiteStatement) -> Tombstone? {
            guard let contentHash = statement.text(0),
                let deletedAt = statement.date(1),
                let deviceID = SQLiteClipMapping.deviceID(statement.text(2))
            else { return nil }
            return Tombstone(contentHash: contentHash, deletedAt: deletedAt, deviceID: deviceID)
        }
    }

#endif
