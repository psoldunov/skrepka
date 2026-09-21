// Checked mutation paths for the Linux SQLite engine. Fenced with its siblings
// because macOS uses HistoryStore instead.
#if os(Linux)

    import Foundation
    import SkrepkaSync

    extension SQLiteHistoryStore {
        /// Sets the pin's exact value, only advancing its sync register on change.
        public func setPinned(_ id: UUID, to pinned: Bool) throws {
            try database.run(
                """
                UPDATE clip SET is_pinned = ?, pinned_at = ?, pinned_by = ?
                WHERE id = ? AND is_pinned != ?
                """,
                [
                    .value(pinned),
                    .value(Date()),
                    .value(localDeviceID?.hex),
                    .value(id),
                    .value(pinned),
                ]
            )
        }

        /// Deletes one row and its sync tombstone, or reports the SQLite failure.
        public func deleteChecked(_ id: UUID) throws {
            defer { pruneExpiredTombstones() }
            try database.transaction {
                guard let row = try clipRow(id: id) else { return }
                try database.run("DELETE FROM clip WHERE id = ?", [.value(id)])
                try recordDeletions(of: [row])
            }
        }

        /// Deletes the requested rows and their tombstones, returning their count.
        public func clearChecked(keepingPinned: Bool = true) throws -> Int {
            defer { pruneExpiredTombstones() }
            let condition = keepingPinned ? " WHERE is_pinned = 0" : ""
            return try database.transaction {
                let doomed = try clipRows(keepingPinned ? .unpinned : .everything)
                try database.run("DELETE FROM clip\(condition)")
                try recordDeletions(of: doomed)
                return doomed.count
            }
        }
    }

#endif
