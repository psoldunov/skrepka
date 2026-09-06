// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import CSQLite
    import Foundation

    /// A SQLite call that did not return `SQLITE_OK`.
    ///
    /// Carries the library's own message rather than only the code: `SQLITE_ERROR`
    /// covers everything from a typo in the SQL to a missing column, and the code
    /// alone cannot tell a reader which. ``statement`` is the SQL that produced it
    /// where one exists — a prepare failure with no SQL beside it is unfixable
    /// from a log.
    public struct SQLiteError: Error, Equatable, CustomStringConvertible {
        public let code: Int32
        public let message: String
        public let statement: String?

        init(code: Int32, message: String, statement: String? = nil) {
            self.code = code
            self.message = message
            self.statement = statement
        }

        /// Builds the error from a live connection, reading `sqlite3_errmsg`.
        ///
        /// Must be called before any further call on the same connection: the
        /// message buffer belongs to the connection and the next call overwrites
        /// it.
        static func read(
            code: Int32,
            database: OpaquePointer?,
            statement: String? = nil
        ) -> SQLiteError {
            let message =
                database
                .map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned \(code) with no connection to describe it."
            return SQLiteError(code: code, message: message, statement: statement)
        }

        public var description: String {
            guard let statement else { return "SQLite error \(code): \(message)" }
            return "SQLite error \(code): \(message) — while running: \(statement)"
        }
    }

    /// What the Linux store refuses to store rather than truncate.
    public enum SQLiteStoreError: Error, Equatable {
        /// A blob larger than `Int32.max`, which `sqlite3_bind_blob` cannot
        /// describe.
        ///
        /// Rejected rather than truncated: a half-written payload is a clipboard
        /// entry that pastes corrupt data, and `SyncLimits.maximumPayloadBytes`
        /// caps anything arriving over the wire at 32 MB long before this. A local
        /// capture that reaches it is a bug worth seeing.
        case blobTooLarge(byteCount: Int)
    }

#endif
