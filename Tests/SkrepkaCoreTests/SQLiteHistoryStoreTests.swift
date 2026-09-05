// What only the SQLite engine can be asked. Everything about *behaviour* lives in
// HistoryStoringTests, which runs against both conformances; this file is the
// claims that are true of the library and the file on disk rather than of the
// store's contract.
#if os(Linux)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    @Suite("SQLite history store")
    struct SQLiteHistoryStoreTests {
        // MARK: - The library

        /// The store's `deinit` closes the connection wherever the last reference
        /// is released, which is not necessarily the actor's executor. That is only
        /// safe because the linked library is built `SQLITE_THREADSAFE=1`.
        ///
        /// Asserted rather than assumed: a distribution that shipped
        /// `SQLITE_THREADSAFE=0` would make `SQLITE_OPEN_FULLMUTEX` a silent no-op
        /// and the close a race, and nothing else in the build would say so.
        @Test("The linked SQLite is thread-safe")
        func theLibraryIsThreadSafe() {
            #expect(SQLiteDatabase.isThreadSafe)
        }

        // MARK: - Binding

        /// `Data.withUnsafeBytes` hands an empty buffer a nil base address, and
        /// `sqlite3_bind_blob` documents a nil pointer as meaning `bind_null` — so
        /// the obvious spelling turns an empty payload into a `NULL` column, and a
        /// representation that holds no bytes becomes indistinguishable from one
        /// this store never fetched.
        @Test("An empty blob round trips as empty, not as NULL")
        func anEmptyBlobIsNotNull() throws {
            let database = try SQLiteDatabase(path: ":memory:")
            try database.execute("CREATE TABLE probe (label TEXT, bytes BLOB)")
            try database.run(
                "INSERT INTO probe (label, bytes) VALUES (?, ?), (?, ?), (?, ?)",
                [
                    .value("empty"), .blob(Data()),
                    .value("absent"), .null,
                    .value("full"), .blob(Data([1, 2, 3])),
                ]
            )

            var read: [String: Data?] = [:]
            try database.query("SELECT label, bytes FROM probe ORDER BY rowid") { statement in
                read[statement.text(0) ?? ""] = statement.blob(1)
            }
            #expect(read["empty"] == Data())
            #expect(read["absent"] == Data?.none)
            #expect(read["full"] == Data([1, 2, 3]))
        }

        /// The `@Attribute(.externalStorage)` replacement, at the size that made
        /// the attribute worth having. `SyncLimits.maximumPayloadBytes` is the
        /// ceiling anything arriving over the wire is held to, so a payload this
        /// large is a supported case rather than a stress test.
        @Test("A payload at the wire's ceiling round trips")
        func aMaximumSizedPayloadRoundTrips() async throws {
            let store = try SQLiteHistoryStore(
                location: nil,
                retention: .unlimited,
                localDeviceID: EngineFixtures.localDevice
            )
            let bytes = Data(repeating: 0x2A, count: SyncLimits.maximumPayloadBytes)
            let item = ClipItem(
                kind: .image,
                text: "big",
                payload: ClipPayload(representations: [PasteboardType.png: bytes]),
                createdAt: EngineFixtures.at(1)
            )
            #expect(await store.capture(item))

            let id = try #require(try await store.summaries().first?.id)
            let payload = try #require(await store.payload(for: id))
            #expect(payload.data(forType: PasteboardType.png)?.count == bytes.count)
            // The index reports the size without the query ever naming `bytes` —
            // which is the whole reason the payload is a second table.
            let entry = try #require(try await store.syncIndex(since: nil).first)
            #expect(entry.representations.first?.byteCount == bytes.count)
        }

        // MARK: - Transactions

        /// `applyRemote` is one transaction because a half-applied merge is the
        /// worst outcome available. This is the mechanism that makes it one.
        @Test("A failing transaction leaves nothing behind")
        func aFailingTransactionRollsBack() throws {
            let database = try SQLiteDatabase(path: ":memory:")
            try database.execute("CREATE TABLE probe (n INTEGER PRIMARY KEY)")

            #expect(throws: SQLiteError.self) {
                try database.transaction {
                    try database.run("INSERT INTO probe (n) VALUES (?)", [.value(1)])
                    // Same primary key. The failure arrives after the first insert
                    // has already been staged, which is the shape a half-applied
                    // merge would have.
                    try database.run("INSERT INTO probe (n) VALUES (?)", [.value(1)])
                }
            }

            var count = -1
            try database.query("SELECT count(*) FROM probe") { count = $0.integer(0) ?? -1 }
            #expect(count == 0)
        }

        // MARK: - The file

        @Test("Deleting a clip takes its payload with it")
        func deletingAClipCascadesToItsRepresentations() async throws {
            let store = try SQLiteHistoryStore(
                location: nil,
                retention: .unlimited,
                localDeviceID: EngineFixtures.localDevice
            )
            #expect(await store.capture(EngineFixtures.item("bytes", at: EngineFixtures.at(1))))
            let id = try #require(try await store.summaries().first?.id)
            #expect(try await store.representationRows(clipID: id).count == 1)

            await store.delete(id)

            // `PRAGMA foreign_keys` is off by default in SQLite and has to be set
            // per connection, so this is the assertion that catches it being
            // dropped: without it the rows survive their clip and the database
            // grows by every payload ever deleted.
            #expect(try await store.representationRows(clipID: id).isEmpty)
        }

        @Test("A store on disk is still there when it is reopened")
        func anOnDiskStorePersists() async throws {
            let directory = Self.temporaryDirectory()
            // A cleanup failure is not a test failure: the temporary directory is
            // named after a fresh UUID, so a leftover collides with nothing.
            defer { try? FileManager.default.removeItem(at: directory) }
            let location = directory.appending(path: "history.sqlite3", directoryHint: .notDirectory)

            let first = try SQLiteHistoryStore(location: location, retention: .unlimited)
            #expect(await first.capture(EngineFixtures.item("durable", at: EngineFixtures.at(1))))

            // The directory is created by the store rather than by the caller, so a
            // fresh machine does not need a mkdir before its first capture.
            #expect(FileManager.default.fileExists(atPath: location.path))

            let second = try SQLiteHistoryStore(location: location, retention: .unlimited)
            #expect(try await second.summaries().map(\.text) == ["durable"])
        }

        /// The history is the plainest copy of everything the user has ever copied:
        /// `clip."text"` and `clip_representation.bytes` hold it in the clear, and
        /// D-7 keeps concealed content off the wire without keeping it out of the
        /// file. `SkrepkaSync`'s `TrustStore` states the standard the repository
        /// holds itself to — 0600, created with it — about a device key that leaks
        /// far less. Without this, Debian's default `DIR_MODE=0755` on `/home`
        /// leaves every other account on a shared machine one
        /// `sqlite3 … 'SELECT "text" FROM clip'` from the lot.
        ///
        /// The sidecars are asserted rather than assumed: SQLite derives their mode
        /// from the database file's, and they carry the same clip text until the
        /// next checkpoint, so "it probably inherits" is not good enough.
        @Test("The store, its directory and its sidecars are readable only by their owner")
        func anOnDiskStoreIsReadableOnlyByItsOwner() async throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let location = directory.appending(path: "history.sqlite3", directoryHint: .notDirectory)

            let store = try SQLiteHistoryStore(location: location, retention: .unlimited)
            #expect(await store.capture(EngineFixtures.item("a secret", at: EngineFixtures.at(1))))

            #expect(try Self.mode(of: directory.path) == 0o700)
            #expect(try Self.mode(of: location.path) == 0o600)
            #expect(try Self.mode(of: location.path + "-wal") == 0o600)
            #expect(try Self.mode(of: location.path + "-shm") == 0o600)
            // Reading through the store last keeps its connection — and so the two
            // sidecars the assertions above name — alive to the end of the test.
            #expect(try await store.summaries().count == 1)
        }

        // MARK: - The schema version

        @Test("Installing stamps the version, and installing again does not rewrite it")
        func installStampsTheVersionOnce() throws {
            let database = try SQLiteDatabase(path: ":memory:")
            try HistorySchema.install(on: database)
            #expect(try HistorySchema.installedVersion(of: database) == HistorySchema.version)

            try HistorySchema.install(on: database)
            #expect(try HistorySchema.installedVersion(of: database) == HistorySchema.version)
        }

        /// `PRAGMA user_version` is the hook D-8 will migrate against, and a hook
        /// that overwrites whatever it finds is the guess it was meant to replace.
        /// A user who rolls back to this build for a week would otherwise have
        /// every open re-stamp a newer database as this one's, and the next upgrade
        /// would re-run a migration against a database that has already had it.
        @Test("A database from a newer build is refused, and is not stamped back down")
        func aNewerDatabaseIsRefused() throws {
            let directory = Self.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let location = directory.appending(path: "history.sqlite3", directoryHint: .notDirectory)

            // Opened and dropped: all this needs is the file and its schema, which
            // a build from the future then stamps its own version onto.
            _ = try SQLiteHistoryStore(location: location, retention: .unlimited)
            let newer = HistorySchema.version + 1
            let raw = try SQLiteDatabase(path: location.path)
            try raw.execute("PRAGMA user_version = \(newer)")

            let refusal = HistorySchema.VersionError.newerThanThisBuild(
                found: newer,
                supported: HistorySchema.version
            )
            #expect(throws: refusal) {
                _ = try SQLiteHistoryStore(location: location, retention: .unlimited)
            }
            #expect(try HistorySchema.installedVersion(of: raw) == newer)
        }

        /// `CREATE TABLE IF NOT EXISTS` does nothing to a table that already
        /// exists, so a column added to ``HistorySchema/clipTable`` reaches an
        /// older database only through ``HistorySchema/migrations``. Forget the
        /// migration and every insert against that database fails on a column
        /// name — which is a state no fresh install can reproduce, so nothing else
        /// in the suite would catch it.
        @Test("A database from an older build gains the columns it is missing")
        func anOlderDatabaseIsMigrated() throws {
            let old = try SQLiteDatabase(path: ":memory:")
            // Version 1's clip table: today's, less the column version 2 added.
            try old.execute(
                """
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
                PRAGMA user_version = 1;
                """
            )

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
            #expect(try Set(Self.columns(of: "clip", in: old)) == Set(Self.columns(of: "clip", in: fresh)))
            #expect(try Self.columns(of: "clip", in: old).contains("content_byte_count"))
        }

        // MARK: - Helpers

        /// The table's column names in declaration order.
        private static func columns(of table: String, in database: SQLiteDatabase) throws -> [String] {
            var names: [String] = []
            try database.query("PRAGMA table_info(\(table))") { statement in
                if let name = statement.text(1) { names.append(name) }
            }
            return names
        }

        private static func temporaryDirectory() -> URL {
            URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
                .appending(path: "skrepka-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        }

        /// The POSIX mode bits of a path.
        ///
        /// Read as `NSNumber` rather than `Int`: that is what
        /// `FileAttributeKey.posixPermissions` is documented to carry, and it is the
        /// cast that answers on swift-corelibs-foundation as well as on Darwin.
        private static func mode(of path: String) throws -> Int? {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue
        }
    }

#endif
