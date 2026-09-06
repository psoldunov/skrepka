// What `HistorySchema` promises about a database file across builds: the version
// it stamps, and what an upgrade does to a table an older build created. Split
// from SQLiteHistoryStoreTests, which is about the library and the store's own
// file. Linux-only for the same reason that file is — the SQLite engine is not
// built on macOS.
#if os(Linux)

    import Testing

    @testable import SkrepkaCore

    @Suite("History schema")
    struct HistorySchemaTests {
        @Test("Installing stamps the version, and installing again does not rewrite it")
        func installStampsTheVersionOnce() throws {
            let database = try SQLiteDatabase(path: ":memory:")
            try HistorySchema.install(on: database)
            #expect(try HistorySchema.installedVersion(of: database) == HistorySchema.version)

            try HistorySchema.install(on: database)
            #expect(try HistorySchema.installedVersion(of: database) == HistorySchema.version)
        }

        /// `CREATE TABLE IF NOT EXISTS` does nothing to a table that already
        /// exists, so a column added to ``HistorySchema/clipTable`` reaches an
        /// older database only through ``HistorySchema/migrations``. Forget the
        /// migration and every insert against that database fails on a column
        /// name — which is a state no fresh install can reproduce, so nothing else
        /// in the suite would catch it.
        @Test("A database from an older build gains the columns it is missing")
        func anOlderDatabaseIsMigrated() throws {
            let old = try Self.versionOneDatabase()

            try HistorySchema.install(on: old)
            #expect(try HistorySchema.installedVersion(of: old) == HistorySchema.version)

            let fresh = try SQLiteDatabase(path: ":memory:")
            try HistorySchema.install(on: fresh)
            // The same columns, as a set rather than a list: `ALTER TABLE ADD
            // COLUMN` can only append, so a migrated table declares the new column
            // last where a fresh one declares it in the middle. Nothing depends on
            // that — every statement in this store names its columns through
            // `SQLiteClipRow.columns`, so the result set is ordered by the query
            // and never by the table. What would break the positional reader is a
            // column *missing*, which is exactly what this compares.
            for table in ["clip", "clip_representation", "tombstone", "paired_device"] {
                #expect(
                    try Set(Self.columns(of: table, in: old))
                        == Set(Self.columns(of: table, in: fresh)),
                    "\(table) drifted between an upgraded database and a fresh one"
                )
            }
            #expect(try Self.columns(of: "clip", in: old).contains("content_byte_count"))
            #expect(try Self.columns(of: "paired_device", in: old).contains("live_push_choice"))
        }

        /// The half-applied upgrade — column added, version not stamped — is the
        /// one state ``HistorySchema/install(on:)`` cannot recover from: the next
        /// open re-runs the `ALTER TABLE` into "duplicate column name", and it
        /// throws out of every open after that. What keeps that state unreachable
        /// is the migration and the stamp sharing one transaction.
        ///
        /// Asserted as a property of that pair rather than by provoking a failure
        /// part-way through `install`. The only thing that fails between those two
        /// statements in production is an I/O error on the header write, and a
        /// test that tries to induce `SQLITE_FULL` or to race a process death is a
        /// flake waiting to be deleted by whoever is on call. So this runs the
        /// real migration and the real stamp through the real helper and fails the
        /// transaction deliberately: deterministic, and it pins the half that is
        /// not obvious. `SQLiteHistoryStoreTests.aFailingTransactionRollsBack`
        /// already covers a rolled-back `INSERT`; what is different here is that
        /// `ALTER TABLE` reverts because DDL is transactional and
        /// `PRAGMA user_version` reverts because it writes the database header.
        /// Let either stop being true and this goes red, rather than a store
        /// quietly becoming unopenable in the field.
        ///
        /// It does not prove `install` itself wraps the two — nothing observable
        /// distinguishes that without an injectable failure. `anOlderDatabaseIsMigrated`
        /// covers the path; this covers the guarantee that path leans on.
        @Test("A migration and its version stamp roll back together or not at all")
        func aFailedMigrationLeavesNoHalfUpgrade() throws {
            // Step 2 by name rather than ``HistorySchema/version``, because the two
            // stop being the same number the moment a third version lands, and a
            // version with nothing to migrate is a case `install` supports on
            // purpose — its loop skips a step with no statement. Pinning the
            // literal keeps this asserting about the upgrade it was written for
            // instead of going red at the next bump; `#require` still fails loudly
            // if migration 2 itself ever disappears.
            let step = 2
            let migration = try #require(HistorySchema.migrations[step])
            let database = try Self.versionOneDatabase()

            #expect(throws: MigrationInterrupted.self) {
                try database.transaction {
                    try database.execute(migration)
                    try database.execute("PRAGMA user_version = \(step)")
                    throw MigrationInterrupted()
                }
            }

            #expect(try HistorySchema.installedVersion(of: database) == step - 1)
            #expect(try !Self.columns(of: "clip", in: database).contains("content_byte_count"))
        }

        // MARK: - Helpers

        /// Stands in for whatever fails after the `ALTER TABLE` has landed.
        private struct MigrationInterrupted: Error {}

        /// A database holding version 1's schema and stamped as such.
        ///
        /// **Frozen.** These are the tables as version 1 shipped them, not a copy
        /// of ``HistorySchema`` kept in step with it — the whole point is to be the
        /// thing today's schema has moved away from. They grow only by
        /// ``HistorySchema/migrations`` running against them, never by hand, and a
        /// column added to a table in `HistorySchema` belongs in a migration rather
        /// than here.
        ///
        /// Forgetting a migration is safe: a column with no migration makes the two
        /// databases' column sets differ and `anOlderDatabaseIsMigrated` goes red.
        /// *Editing* this is what would be quiet — adding a column here that the
        /// current schema already has would make both sides agree while this
        /// fixture claimed a shape version 1 never had, hiding the missing
        /// migration it was meant to catch. Hence the counts below: they are
        /// historical facts about a released schema, so pinning them costs nothing
        /// and no legitimate change ever moves them.
        ///
        /// **Every table version 1 had, not only the one under test.** A table this
        /// fixture omits is created from scratch by `install`, in *today's* shape —
        /// and then the migration that adds a column to it runs against a table
        /// that already has it, which is "duplicate column name" and a red test
        /// that says nothing about the change being made. A version 1 database had
        /// all four of these, so this has all four.
        private static func versionOneDatabase() throws -> SQLiteDatabase {
            let database = try SQLiteDatabase(path: ":memory:")
            try database.execute(Self.versionOneSchema)
            #expect(try columns(of: "clip", in: database).count == 14)
            #expect(try columns(of: "paired_device", in: database).count == 6)
            return database
        }

        /// Version 1's four tables, verbatim, and the stamp that says so.
        private static let versionOneSchema = """
            CREATE TABLE clip (
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
                thumbnail BLOB,
                pinned_at REAL,
                pinned_by TEXT,
                origin_device_id TEXT
            );
            CREATE TABLE clip_representation (
                clip_id TEXT NOT NULL REFERENCES clip(id) ON DELETE CASCADE,
                "type" TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                bytes BLOB,
                PRIMARY KEY (clip_id, "type")
            );
            CREATE TABLE tombstone (
                content_hash TEXT PRIMARY KEY NOT NULL,
                deleted_at REAL NOT NULL,
                device_id TEXT NOT NULL
            );
            CREATE TABLE paired_device (
                device_id TEXT PRIMARY KEY NOT NULL,
                device_name TEXT NOT NULL,
                platform_raw TEXT NOT NULL,
                certificate_der BLOB NOT NULL,
                paired_at REAL NOT NULL,
                highest_protocol_seen INTEGER
            );
            PRAGMA user_version = 1;
            """

        /// The table's column names in declaration order.
        private static func columns(of table: String, in database: SQLiteDatabase) throws -> [String] {
            var names: [String] = []
            try database.query("PRAGMA table_info(\(table))") { statement in
                if let name = statement.text(1) { names.append(name) }
            }
            return names
        }
    }

#endif
