// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import CSQLite
    import Foundation

    /// `SQLITE_TRANSIENT` is `((sqlite3_destructor_type)-1)` in `sqlite3.h` — a
    /// sentinel rather than an address, so the C macro does not import into Swift
    /// and naming it means rebuilding the same bit pattern. Read from
    /// `/usr/include/sqlite3.h:6066` in the build container rather than
    /// remembered.
    ///
    /// It is the only safe choice here: SQLite copies the bytes before
    /// `sqlite3_bind_*` returns, so nothing this file binds has to outlive the
    /// call. `SQLITE_STATIC` would hand SQLite a pointer into a Swift buffer whose
    /// lifetime ends at the closure's brace — a dangling bind is silent
    /// corruption, not a crash.
    private let sqliteTransient = unsafeBitCast(
        -1,
        to: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?.self
    )

    /// One prepared statement.
    ///
    /// A class so `deinit` finalises the handle. That is the whole reason it is
    /// not a struct: a statement has to be finalised on every path out of the
    /// function that made it, including the throwing ones, and ARC does that
    /// correctly where a `defer` in each caller would eventually not.
    final class SQLiteStatement {
        private let handle: OpaquePointer
        private let database: OpaquePointer
        private let sql: String

        init(database: OpaquePointer, sql: String) throws {
            var handle: OpaquePointer?
            let code = sqlite3_prepare_v2(database, sql, -1, &handle, nil)
            guard code == SQLITE_OK, let handle else {
                sqlite3_finalize(handle)
                throw SQLiteError.read(code: code, database: database, statement: sql)
            }
            self.handle = handle
            self.database = database
            self.sql = sql
        }

        deinit { sqlite3_finalize(handle) }

        // MARK: - Binding

        /// Binds every parameter, in the order the SQL declares them.
        ///
        /// Resets first, so a statement reused across a batch cannot carry a
        /// leftover binding into the next row.
        func bind(_ values: [SQLiteValue]) throws {
            try reset()
            for (offset, value) in values.enumerated() {
                try bind(value, at: Int32(offset + 1))
            }
        }

        private func bind(_ value: SQLiteValue, at index: Int32) throws {
            switch value {
            case .null:
                try check(sqlite3_bind_null(handle, index))
            case .integer(let number):
                try check(sqlite3_bind_int64(handle, index, number))
            case .double(let number):
                try check(sqlite3_bind_double(handle, index, number))
            case .text(let string):
                try check(sqlite3_bind_text(handle, index, string, -1, sqliteTransient))
            case .blob(let data):
                try check(try bindBlob(data, at: index))
            }
        }

        /// Empty data is bound with `sqlite3_bind_zeroblob(_:_:0)`.
        ///
        /// `Data.withUnsafeBytes` hands an empty buffer a `nil` base address, and
        /// `sqlite3_bind_blob` documents a `NULL` pointer as meaning `bind_null` —
        /// so the obvious spelling turns an empty payload into a `NULL` column and
        /// the round trip stops being one.
        private func bindBlob(_ data: Data, at index: Int32) throws -> Int32 {
            guard data.count <= Int32.max else {
                throw SQLiteStoreError.blobTooLarge(byteCount: data.count)
            }
            guard !data.isEmpty else { return sqlite3_bind_zeroblob(handle, index, 0) }
            return data.withUnsafeBytes { buffer in
                sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
        }

        // MARK: - Running

        /// Advances one row. `true` while there is a row to read.
        func step() throws -> Bool {
            let code = sqlite3_step(handle)
            switch code {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError.read(code: code, database: database, statement: sql)
            }
        }

        /// Runs a statement that returns no rows.
        func run() throws {
            while try step() {}
        }

        func reset() throws {
            // `sqlite3_reset` reports the error of the *previous* step, which
            // `step()` has already thrown. Clearing the bindings is the part that
            // matters here, and it cannot fail.
            sqlite3_reset(handle)
            try check(sqlite3_clear_bindings(handle))
        }

        // MARK: - Reading

        /// Whether the column holds `NULL` — the one question every optional
        /// column has to be asked before it is read, because `sqlite3_column_int`
        /// answers 0 either way.
        func isNull(_ index: Int32) -> Bool {
            sqlite3_column_type(handle, index) == SQLITE_NULL
        }

        func text(_ index: Int32) -> String? {
            guard !isNull(index), let bytes = sqlite3_column_text(handle, index) else { return nil }
            return String(cString: bytes)
        }

        func integer(_ index: Int32) -> Int? {
            guard !isNull(index) else { return nil }
            return Int(sqlite3_column_int64(handle, index))
        }

        func double(_ index: Int32) -> Double? {
            guard !isNull(index) else { return nil }
            return sqlite3_column_double(handle, index)
        }

        func date(_ index: Int32) -> Date? {
            double(index).map(Date.init(timeIntervalSinceReferenceDate:))
        }

        func bool(_ index: Int32) -> Bool {
            (integer(index) ?? 0) != 0
        }

        /// An empty blob reads back as empty `Data`, not `nil` — `NULL` is the
        /// only thing that means "absent", which is what lets a representation
        /// row say "this many bytes, none of them here".
        func blob(_ index: Int32) -> Data? {
            guard !isNull(index) else { return nil }
            let count = Int(sqlite3_column_bytes(handle, index))
            guard count > 0, let bytes = sqlite3_column_blob(handle, index) else { return Data() }
            return Data(bytes: bytes, count: count)
        }

        private func check(_ code: Int32) throws {
            guard code != SQLITE_OK else { return }
            throw SQLiteError.read(code: code, database: database, statement: sql)
        }
    }

#endif
