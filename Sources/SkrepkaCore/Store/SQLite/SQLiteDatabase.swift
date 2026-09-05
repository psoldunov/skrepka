// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import CSQLite
    import Foundation

    /// One SQLite connection, and the only thing in the store that touches C.
    ///
    /// Not `Sendable`, deliberately. ``SQLiteHistoryStore`` is an actor and owns
    /// exactly one of these, so isolation — not a lock and not a claim the
    /// compiler cannot check — is what keeps two tasks off the handle.
    ///
    /// The handle is nonetheless opened `SQLITE_OPEN_FULLMUTEX`. The library is
    /// built `SQLITE_THREADSAFE=1` here (verified with `sqlite3_threadsafe()`
    /// against the container's 3.45.1, not assumed), and `deinit` runs wherever
    /// the last reference is released — which is not necessarily the actor's
    /// executor. Serialised mode makes that close safe for the price of an
    /// uncontended mutex per call.
    final class SQLiteDatabase {
        private let handle: OpaquePointer

        /// Whether the linked library was built `SQLITE_THREADSAFE=1`.
        ///
        /// Exposed because ``deinit`` depends on it: a distribution shipping a
        /// single-threaded build would make `SQLITE_OPEN_FULLMUTEX` a silent no-op
        /// and closing from another thread a race, and nothing else in the build
        /// would say so. `SQLiteHistoryStoreTests` asserts it.
        static var isThreadSafe: Bool { sqlite3_threadsafe() != 0 }

        /// `SQLITE_OPEN_CREATE` is here because a first run has no file yet, and
        /// nothing about `sqlite3_open_v2` constrains the mode of one it creates —
        /// it would land at `0666 & ~umask`, world-readable under the usual 022.
        /// So the file is expected to exist already, created at 0600 by
        /// ``SQLiteHistoryStore/prepareOnDisk(_:)``; the flag is the fallback for a
        /// path nothing prepared, and any new caller opening one owes it the same
        /// preparation.
        ///
        /// - Parameter path: a filesystem path, or `":memory:"` for a private
        ///   database that lives as long as this connection.
        init(path: String) throws {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            let code = sqlite3_open_v2(path, &handle, flags, nil)
            guard code == SQLITE_OK, let handle else {
                // sqlite3_open_v2 allocates a connection even when it fails, and
                // the message lives on it — so read the message first and close
                // second, or the failure is reported as a bare code.
                let error = SQLiteError.read(code: code, database: handle, statement: "open \(path)")
                sqlite3_close_v2(handle)
                throw error
            }
            self.handle = handle
        }

        deinit { sqlite3_close_v2(handle) }

        // MARK: - Running

        /// Runs one or more statements that take no parameters and return no rows.
        ///
        /// `sqlite3_exec` rather than prepare/step because the schema arrives as
        /// one script and splitting it on semicolons by hand is a parser nobody
        /// should write.
        func execute(_ sql: String) throws {
            let code = sqlite3_exec(handle, sql, nil, nil, nil)
            guard code == SQLITE_OK else {
                throw SQLiteError.read(code: code, database: handle, statement: sql)
            }
        }

        func prepare(_ sql: String) throws -> SQLiteStatement {
            try SQLiteStatement(database: handle, sql: sql)
        }

        /// Prepares, binds and runs a statement that returns no rows.
        func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
            let statement = try prepare(sql)
            try statement.bind(values)
            try statement.run()
        }

        /// Prepares, binds and reads every row, handing each to `read`.
        ///
        /// Streaming rather than returning an array of rows: a row's accessors are
        /// only valid until the next `step()`, so handing them out would be an
        /// invitation to read a freed buffer.
        func query(
            _ sql: String,
            _ values: [SQLiteValue] = [],
            read: (SQLiteStatement) throws -> Void
        ) throws {
            let statement = try prepare(sql)
            try statement.bind(values)
            while try statement.step() {
                try read(statement)
            }
        }

        // MARK: - Transactions

        /// Runs `body` inside one transaction, rolling back if it throws.
        ///
        /// `BEGIN IMMEDIATE` rather than the deferred default: a deferred
        /// transaction takes its write lock at the first write, so two writers can
        /// both begin and one then fails with `SQLITE_BUSY` partway through. Taking
        /// the lock up front turns that into a wait at the start instead.
        ///
        /// Not re-entrant, and does not pretend to be — a nested call would commit
        /// the outer transaction early. Every caller here is a top-level store
        /// operation.
        func transaction<T>(_ body: () throws -> T) throws -> T {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try body()
                try execute("COMMIT")
                return result
            } catch {
                // The rollback's own failure must not replace the error that
                // caused it: the first one says what went wrong, and this one
                // would say only that the transaction was already gone.
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

#endif
