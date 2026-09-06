// The capture path, split from SQLiteHistoryStore.swift for the reason
// HistoryStore+Capture.swift is split from HistoryStore.swift: what a new
// clipping does to the store is one story, and it is long enough to tell on its
// own. Fenced to Linux with the rest of this directory (D-3).
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    extension SQLiteHistoryStore {
        /// Stores a newly captured item, collapsing a repeat copy onto the entry it
        /// duplicates rather than adding a second row.
        ///
        /// No thumbnail is rendered. That needs `ThumbnailMaker`, which is AppKit,
        /// and D-9 defers `ThumbnailProducing` to Phase 7 rather than giving macOS
        /// a protocol with a nil-returning stub behind it — so a Linux row carries
        /// the dimensions the capture already knew and no picture.
        @discardableResult
        public func capture(_ item: ClipItem) -> Bool {
            do {
                try database.transaction {
                    if let existing = try clipRow(contentHash: item.contentHash) {
                        try database.run(
                            """
                            UPDATE clip SET created_at = ?, source_bundle_id = ? WHERE id = ?
                            """,
                            [
                                .value(item.createdAt),
                                .value(item.sourceBundleID ?? existing.sourceBundleID),
                                .value(existing.id),
                            ]
                        )
                        try relistFiles(of: item, onto: existing)
                        return
                    }
                    let row = SQLiteClipRow.make(from: item, originDeviceID: localDeviceID?.hex)
                    try insert(row, representations: SQLiteRepresentationMapping.rows(from: item.payload))
                }
                try applyRetention()
                return true
            } catch {
                SkrepkaLog.store.error("Failed to store clipboard entry: \(error.localizedDescription)")
                return false
            }
        }

        /// Relists the files a repeat copy proves the entry holds, and renames it
        /// from them.
        ///
        /// The counterpart of `HistoryStore.backfillFiles(from:into:)`, written
        /// as its own statement rather than folded into the `UPDATE` above
        /// because it applies to file entries alone: a repeat copy of text has no
        /// file list to write and must not have its text rewritten.
        ///
        /// Landing here proves this copy holds the same files the row does — the
        /// hash covers every one of them, see
        /// ``ClipItem/hash(kind:text:payload:fileURLs:)`` — so the list and the
        /// name it is built from are written together. A row that predates the
        /// column, or was stored when only the first file was kept, is corrected
        /// by the next copy of the same selection.
        private func relistFiles(of item: ClipItem, onto existing: SQLiteClipRow) throws {
            guard item.kind.isFileSystemEntry, !item.fileURLs.isEmpty else { return }
            let encoded = try SelectionCoding.encode(
                fileURLStrings: item.fileURLs.map(\.absoluteString)
            )
            try database.run(
                "UPDATE clip SET file_urls = ?, \"text\" = ? WHERE id = ?",
                [.value(encoded), .value(item.text), .value(existing.id)]
            )
        }
    }

#endif
