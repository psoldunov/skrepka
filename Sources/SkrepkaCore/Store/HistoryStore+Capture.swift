// The capture path, split from HistoryStore.swift: what a new clipping does to
// the store, from the off-actor detail pass to the row it lands on. Linux
// captures through the SQLite conformance in `Store/SQLite/` (D-3, D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    extension HistoryStore {
        /// Stores a newly captured item, collapsing a repeat copy onto the entry it
        /// duplicates rather than adding a second row.
        ///
        /// Asynchronous because reading what a row needs off the copied thing —
        /// its preview, its size, whether it is a folder — belongs off this actor,
        /// see ``ThumbnailRenderer``. Captures arrive one at a time from the
        /// watcher's stream, so the suspension does not interleave two of them.
        @discardableResult
        public func capture(_ item: ClipItem) async -> Bool {
            // Read before the context is touched, so no SwiftData work spans the
            // suspension.
            let details = await thumbnailRenderer.details(for: item)

            do {
                if let existing = try recordMatching(contentHash: item.contentHash) {
                    existing.createdAt = item.createdAt
                    existing.sourceBundleID = item.sourceBundleID ?? existing.sourceBundleID
                    backfillDetails(details, into: existing)
                    try context.save()
                    project(upserts: [existing])
                    return true
                }

                let record = try ClipRecordMapping.makeRecord(
                    from: item,
                    details: details,
                    originDeviceID: localDeviceID?.hex
                )
                context.insert(record)
                try context.save()
                project(upserts: [record])
                applyRetention()
                return true
            } catch {
                // The list is maintained by delta, so a mutation that threw before
                // it could publish one leaves `items` describing a store that has
                // moved on. Rebuilding is the recovery path — see ``reload()``.
                reload()
                SkrepkaLog.store.error("Failed to store clipboard entry: \(error.localizedDescription)")
                return false
            }
        }

        /// Writes what this capture learned onto the entry it collapsed onto.
        ///
        /// A repeat copy is the only chance any row gets to be corrected: nothing
        /// else revisits one, and the de-duplication above is what a repeat copy
        /// hits. Every part follows the same rule — a real answer overwrites a
        /// missing one, and a missing one never overwrites a real one.
        private func backfillDetails(_ details: ClipDetails, into record: ClipRecord) {
            // A folder stored before Skrepka told folders from files still reads
            // "File". Its hash matches — see ``ClipKind/hashDomain`` — so a repeat
            // copy lands here, and this is the one place that can correct it.
            //
            // Only when the disk actually answered, though. A re-copy of a folder
            // since deleted or on an ejected volume yields no kind at all, and
            // writing the capture rules' guess of `.file` over a row already saying
            // Folder would put the original bug back.
            if let kind = details.kind { record.kindRaw = kind.rawValue }
            // Same rule for the size: the entry predates sizes, or the folder was
            // too large to walk that time. An existing measurement is kept when
            // this one came back empty, so a moved file does not lose the size it
            // was copied at.
            record.byteCount = details.byteCount ?? record.byteCount
            backfillPreview(details.preview, into: record)
        }

        /// Fills in a preview the entry never got.
        ///
        /// An entry stored before `.file` earned previews has no thumbnail, and so
        /// does one whose file was unreadable at the time. Without this those rows
        /// keep a generic document icon for good.
        ///
        /// An existing thumbnail is left alone. The row is a snapshot of the copy
        /// that made it, and replacing it would silently rewrite history.
        private func backfillPreview(_ preview: ThumbnailMaker.Preview?, into record: ClipRecord) {
            guard record.thumbnailData == nil, let preview else { return }
            record.thumbnailData = preview.thumbnail
            record.imageWidth = preview.pixelSize?.width
            record.imageHeight = preview.pixelSize?.height
        }
    }

#endif
