// The Linux store's queries, kept out of the main file so the behaviour there
// reads as behaviour. Raw SQLite is the Linux engine (D-3) and macOS never
// resolves the CSQLite target, so this is fenced to Linux.
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    extension SQLiteHistoryStore {
        // MARK: - Clips

        /// Every clip the filter admits, with `trailing` — an `ORDER BY`, a
        /// `LIMIT`, or both — appended.
        func clipRows(_ filter: ClipFilter, trailing: String? = nil) throws -> [SQLiteClipRow] {
            var sql = "SELECT \(SQLiteClipRow.columns) FROM clip"
            if let condition = filter.condition { sql += " WHERE \(condition)" }
            if let trailing { sql += " \(trailing)" }

            var rows: [SQLiteClipRow] = []
            var skipped = 0
            try database.query(sql, filter.values) { statement in
                guard let row = SQLiteClipRow(statement: statement) else {
                    skipped += 1
                    return
                }
                rows.append(row)
            }
            if skipped > 0 {
                SkrepkaLog.store.error(
                    "Skipped \(skipped) history rows whose stored columns do not parse."
                )
            }
            return rows
        }

        func clipRow(id: UUID) throws -> SQLiteClipRow? {
            try clipRows(.id(id), trailing: "LIMIT 1").first
        }

        /// The lookup identity across machines. Every merge action and every
        /// capture runs it, which is why `clip_by_content_hash` exists.
        ///
        /// Deliberately unfiltered: this answers "is this content already here",
        /// and a concealed row is here. `payload(for:key:)` is the serving side and
        /// scopes itself by ``ClipFilter/syncable(since:qualifier:)`` instead —
        /// filtering here would let a peer's offer land a second row beside a
        /// concealed one the user already holds.
        func clipRow(contentHash: String) throws -> SQLiteClipRow? {
            try clipRows(.contentHash(contentHash), trailing: "LIMIT 1").first
        }

        /// Whether a row exists, without reading it.
        ///
        /// Separate from ``clipRow(id:)`` because ``SQLiteHistoryStore/payload(for:)``
        /// has to tell "no such entry" from "an entry holding no bytes", and
        /// reading fourteen columns to answer a yes-or-no question is work nobody
        /// asked for.
        func clipExists(id: UUID) throws -> Bool {
            var found = false
            try database.query("SELECT 1 FROM clip WHERE id = ? LIMIT 1", [.value(id)]) { _ in
                found = true
            }
            return found
        }

        /// Inserts a clip and its representations. Caller owns the transaction.
        func insert(_ row: SQLiteClipRow, representations: [SQLiteRepresentationRow]) throws {
            try database.run(SQLiteClipRow.insert, row.bindings)
            guard !representations.isEmpty else { return }
            let statement = try database.prepare(SQLiteRepresentationRow.insert)
            for representation in representations {
                try statement.bind(representation.bindings(clipID: row.id))
                try statement.run()
            }
        }

        // MARK: - Representations

        func representationRows(clipID: UUID) throws -> [SQLiteRepresentationRow] {
            var rows: [SQLiteRepresentationRow] = []
            try database.query(
                """
                SELECT "type", byte_count, bytes FROM clip_representation WHERE clip_id = ?
                """,
                [.value(clipID)]
            ) { statement in
                guard let row = SQLiteRepresentationRow(statement: statement) else { return }
                rows.append(row)
            }
            return rows
        }

        /// The representation index of every clip the filter admits, keyed by clip
        /// id.
        ///
        /// One query for the whole index offer rather than one per row, and it
        /// never names `bytes` — which is the entire point of the two-table shape.
        /// A 500-item offer reads a few kilobytes of counts instead of pulling
        /// every payload off disk to measure it.
        func representationIndexes(_ filter: ClipFilter) throws -> [UUID: [String: Int]] {
            var sql = """
                SELECT r.clip_id, r."type", r.byte_count
                FROM clip_representation r JOIN clip c ON c.id = r.clip_id
                """
            if let condition = filter.condition { sql += " WHERE \(condition)" }

            var indexes: [UUID: [String: Int]] = [:]
            try database.query(sql, filter.values) { statement in
                guard let idText = statement.text(0),
                    let id = UUID(uuidString: idText),
                    let type = statement.text(1),
                    let byteCount = statement.integer(2)
                else { return }
                indexes[id, default: [:]][type] = byteCount
            }
            return indexes
        }

        /// The bytes of one representation of one clip, or nil when this store
        /// does not hold them.
        func representationBytes(clipID: UUID, types: [String]) throws -> Data? {
            for type in types {
                var bytes: Data?
                try database.query(
                    """
                    SELECT bytes FROM clip_representation WHERE clip_id = ? AND "type" = ?
                    """,
                    [.value(clipID), .value(type)]
                ) { statement in
                    bytes = statement.blob(0)
                }
                if let bytes { return bytes }
            }
            return nil
        }
    }

#endif
