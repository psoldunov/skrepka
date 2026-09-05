// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation

    /// The Linux store's tables, in one place.
    ///
    /// **This schema is defined twice** — once here and once as the `@Model` types
    /// in `Store/`. That is the standing cost of two engines that
    /// `docs/linux-sync/phase-4-core-on-linux.md` names, and a column added on one
    /// side and forgotten on the other is the failure mode. `HistoryStoringTests`
    /// runs against both conformances for exactly this reason.
    ///
    /// Column-for-column with `ClipRecord`, `TombstoneRecord` and
    /// `PairedDeviceRecord`, with one deliberate difference: payload bytes and the
    /// representation index are one table here rather than a property-list blob
    /// plus a denormalised column. See ``representationTable``.
    enum HistorySchema {
        /// Bumped when a column changes, and read as well as written — which is
        /// what makes it a hook rather than a decoration. See ``install(on:)``.
        ///
        /// - 1: the original three tables.
        /// - 2: `clip.content_byte_count`, following `ClipRecord.byteCount` onto
        ///   this engine.
        ///
        /// The Linux store still has no installed base
        /// ([D-8](../../../docs/linux-sync/open-questions.md)), so v2 is reached
        /// almost only by a fresh `CREATE TABLE`. ``migrations`` exists anyway
        /// because a developer's own store from last week is exactly the database
        /// `CREATE TABLE IF NOT EXISTS` would silently leave a column short, and
        /// every insert against it would then fail on a column name.
        static let version = 2

        /// Applied to the connection before anything else touches it.
        ///
        /// - `foreign_keys` is **off by default** in SQLite and has to be turned on
        ///   per connection. `clip_representation`'s cascade is what removes a
        ///   payload when its clip goes, so without this a delete silently orphans
        ///   megabytes.
        /// - `journal_mode = WAL` lets the Phase 6 daemon read while it writes. It
        ///   is a no-op on `:memory:`, which returns `memory` instead — not an
        ///   error, so tests need no special case.
        /// - `busy_timeout` turns a concurrent writer into a wait rather than an
        ///   immediate `SQLITE_BUSY`.
        static let pragmas = """
            PRAGMA foreign_keys = ON;
            PRAGMA journal_mode = WAL;
            PRAGMA busy_timeout = 5000;
            """

        /// The history row. Every column mirrors a `ClipRecord` property, and every
        /// nullable one mirrors an optional there — a `NULL` means exactly what a
        /// `nil` means on the other engine.
        ///
        /// `created_at` is indexed because every list and every index offer sorts
        /// by it; `content_hash` because it is the identity every lookup, merge and
        /// tombstone uses. Neither is `UNIQUE`: the SwiftData side has no unique
        /// constraint either and de-duplicates by hand, and adding one here would
        /// make an insert *throw* where macOS silently keeps one row.
        ///
        /// `content_byte_count` is `ClipRecord.byteCount`, spelled longer than the
        /// property because ``representationTable`` already has a `byte_count` and
        /// the two measure different things: this one is the size of the copied
        /// file, folder or picture, that one is the size of one representation of
        /// it. A query joining both would otherwise name the same column twice.
        static let clipTable = """
            CREATE TABLE IF NOT EXISTS clip (
                id TEXT PRIMARY KEY NOT NULL,
                kind_raw TEXT NOT NULL,
                "text" TEXT NOT NULL,
                source_bundle_id TEXT,
                created_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL,
                is_concealed INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                image_width INTEGER,
                image_height INTEGER,
                content_byte_count INTEGER,
                thumbnail BLOB,
                pinned_at REAL,
                pinned_by TEXT,
                origin_device_id TEXT
            );
            CREATE INDEX IF NOT EXISTS clip_by_content_hash ON clip(content_hash);
            CREATE INDEX IF NOT EXISTS clip_by_created_at ON clip(created_at);
            """

        /// One row per representation — **this is what replaces
        /// `@Attribute(.externalStorage)`.**
        ///
        /// SwiftData keeps every representation in one property-list blob on the
        /// clip row and pushes it out of line, plus a second denormalised column
        /// holding byte counts so an index offer costs no external read. One table
        /// does both jobs: no query that lists history mentions `bytes`, so the
        /// blob is never loaded to draw a row or describe an item, and `byte_count`
        /// is right there beside it.
        ///
        /// `bytes` is nullable and `byte_count` is not, which is the shape the
        /// protocol needs: an item learned from a peer knows how large each
        /// representation is long before the transport fetches any of them
        /// (design §7, metadata eager and payload lazy). `NULL` bytes is
        /// `payload(for:key:)` returning nil — an ordinary answer, not a fault.
        ///
        /// `ON DELETE CASCADE` is why every delete path in this store is one
        /// statement: removing a clip removes its payload with it, inside the same
        /// transaction, with nothing to forget.
        static let representationTable = """
            CREATE TABLE IF NOT EXISTS clip_representation (
                clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
                "type" TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                bytes BLOB,
                PRIMARY KEY (clip_id, "type")
            );
            """

        /// Deletions, keyed by content rather than by row — a `UUID` cannot survive
        /// the round trip because two machines that copied the same string
        /// generated different ones.
        ///
        /// `content_hash` is the primary key here where `TombstoneRecord` has no
        /// unique constraint. Folding two records of one deletion is
        /// `Tombstone.merged(with:)` on both engines, so the constraint only
        /// forecloses a state the SwiftData side also never intends to reach.
        static let tombstoneTable = """
            CREATE TABLE IF NOT EXISTS tombstone (
                content_hash TEXT PRIMARY KEY NOT NULL,
                deleted_at REAL NOT NULL,
                device_id TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS tombstone_by_deleted_at ON tombstone(deleted_at);
            """

        /// Paired peers. `certificate_der` is the pinning material; `device_id` is
        /// a denormalisation of it that `SQLitePairedDeviceMapping` refuses to
        /// trust when the two disagree.
        static let pairedDeviceTable = """
            CREATE TABLE IF NOT EXISTS paired_device (
                device_id TEXT PRIMARY KEY NOT NULL,
                device_name TEXT NOT NULL,
                platform_raw TEXT NOT NULL,
                certificate_der BLOB NOT NULL,
                paired_at REAL NOT NULL,
                highest_protocol_seen INTEGER
            );
            """

        /// What each version added to a database created by the one before it,
        /// keyed by the version it produces.
        ///
        /// Only reached by a database an older build already created: a fresh one
        /// gets every column from the `CREATE TABLE` above, and stamps ``version``
        /// without running any of these. That is what makes each statement safe to
        /// leave out of the fresh path — the two must always agree, and
        /// `HistorySchemaTests` opens an upgraded store and a fresh one and
        /// asserts they hold the same set of columns. A *set*, because
        /// `ALTER TABLE ADD COLUMN` can only append: the two tables declare their
        /// columns in different orders and nothing here cares, since every
        /// statement names the columns it wants through `SQLiteClipRow.columns`.
        static let migrations: [Int: String] = [
            2: "ALTER TABLE clip ADD COLUMN content_byte_count INTEGER"
        ]

        /// Opens the schema on a fresh or existing connection.
        ///
        /// Every `CREATE` is `IF NOT EXISTS`, so this runs on every open rather than
        /// only the first — there is no "is it installed?" question to get wrong,
        /// and a table dropped by hand comes back.
        ///
        /// ``version`` is read first and only ever written forwards. Stamping it
        /// unconditionally is the same guess a store that never wrote it is, with an
        /// extra step: a user who rolls back to this build for a week would have
        /// every open re-stamp a v2 database as v1, and the next upgrade would then
        /// re-run a migration against a database that has already had it — an
        /// `ALTER TABLE … ADD COLUMN` throwing "duplicate column name", or a
        /// backfill running twice over converted rows.
        ///
        /// A database from a newer build is refused outright rather than opened and
        /// written to. This build's statements would run happily against it — they
        /// only name columns it knows — and every capture would then write rows the
        /// newer build's columns are missing from. The check comes before the
        /// pragmas for the same reason: `journal_mode` is a persistent property of
        /// the file, not a setting on this connection.
        ///
        /// **``migrations`` and the stamp that records them land together or not at
        /// all, and a later migration has to stay inside that transaction.** Apart
        /// they are two separately committed statements, and the gap between them
        /// is not recoverable: an `ALTER TABLE` that commits followed by a stamp
        /// that does not — a crash, or one transient `SQLITE_FULL` on the header
        /// write — leaves a database carrying the new column and still reading the
        /// old version. The next open re-runs the same `ALTER TABLE` into
        /// "duplicate column name", which throws out of here, out of
        /// `SQLiteHistoryStore.init`, and out of every open after that. A store
        /// nobody can reopen is a worse outcome than the upgrade never happening,
        /// and one `BEGIN IMMEDIATE` is the whole difference: both statements roll
        /// back — `ALTER TABLE` as DDL, `PRAGMA user_version` because it writes the
        /// database header — so the pair is all-or-nothing and a failed upgrade is
        /// simply retried on the next open. `pragmas` stays outside, because
        /// `journal_mode` cannot be set inside a transaction at all.
        static func install(on database: SQLiteDatabase) throws {
            let installed = try installedVersion(of: database)
            guard installed <= version else {
                throw VersionError.newerThanThisBuild(found: installed, supported: version)
            }

            try database.execute(pragmas)
            try database.execute(clipTable)
            try database.execute(representationTable)
            try database.execute(tombstoneTable)
            try database.execute(pairedDeviceTable)

            guard installed < version else { return }
            try database.transaction {
                // Skipped entirely for a database nothing has stamped: version 0 is
                // both a brand new file and one written before this pragma existed,
                // and the `CREATE TABLE`s above have just given either every column.
                // Running an `ALTER TABLE` on that is "duplicate column name".
                if installed > 0 {
                    for step in (installed + 1)...version {
                        guard let statement = migrations[step] else { continue }
                        try database.execute(statement)
                    }
                }
                try database.execute("PRAGMA user_version = \(version)")
            }
        }

        /// The version stamped on this database, or 0 for one nothing has stamped.
        ///
        /// `PRAGMA user_version` is 0 on a database SQLite has just created, and 0
        /// is also what a store written before this pragma existed reads as — the
        /// same answer for the same reason, so both take the write-forward path.
        static func installedVersion(of database: SQLiteDatabase) throws -> Int {
            var installed = 0
            try database.query("PRAGMA user_version") { statement in
                installed = statement.integer(0) ?? 0
            }
            return installed
        }

        /// A store this build must not touch.
        enum VersionError: Error, Equatable, LocalizedError {
            /// The database was written by a newer Skrepka than this one.
            case newerThanThisBuild(found: Int, supported: Int)

            /// Written for a user rather than a log: the only two things they can do
            /// about it are update and start over, so both are named.
            var errorDescription: String? {
                switch self {
                case .newerThanThisBuild(let found, let supported):
                    return """
                        This copy of Skrepka is too old to open its clipboard history: \
                        the history was last written by a newer version (format \(found); \
                        this one understands \(supported)). Update Skrepka, or move \
                        the history file aside to start a new one.
                        """
                }
            }
        }
    }

#endif
