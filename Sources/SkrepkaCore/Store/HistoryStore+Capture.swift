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
                    backfillDetails(details, from: item, into: existing)
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
        /// hits. Most parts follow one rule — a real answer overwrites a missing
        /// one, and a missing one never overwrites a real one. The two that hold
        /// the copied *files* are the exception, and say why below.
        private func backfillDetails(
            _ details: ClipDetails,
            from item: ClipItem,
            into record: ClipRecord
        ) {
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
            backfillFiles(from: item, into: record)
            backfillPreview(details.preview, into: record)
            backfillStack(details.stackIcons, into: record)
        }

        /// Relists the files the entry holds, and renames it from them.
        ///
        /// A file entry stored before Skrepka kept the files it holds has none
        /// listed, and it was named from the pasteboard's own text rather than
        /// from its files — a Finder copy of three wrote three display names
        /// there while only the first was ever kept, so the row read "3 lines"
        /// and pasted one file.
        ///
        /// Landing here proves this copy holds the same files the row does: the
        /// hash covers every one of them, see
        /// ``ClipItem/hash(kind:text:payload:fileURLs:)``. So both are written,
        /// and together — writing the list alone left the row naming three files
        /// under a label that said one.
        private func backfillFiles(from item: ClipItem, into record: ClipRecord) {
            guard item.kind.isFileSystemEntry, !item.fileURLs.isEmpty else { return }
            record.fileURLStrings = item.fileURLs.map(\.absoluteString)
            record.text = item.text
        }

        /// Gives a row the stack of file icons it was stored without.
        ///
        /// Every entry captured before stacks existed has none, and so does one
        /// whose files were unreadable at the time. A stack that is already
        /// there is replaced rather than kept — the one place this file departs
        /// from the preview's rule — because ``backfillFiles(from:into:)``
        /// replaces the file list in the same breath, and a stack left over from
        /// the previous copy would picture files this row no longer holds.
        ///
        /// Assigned rather than coalesced, so nil clears it. The hash covers the
        /// file *set*, not the order it was clicked in — see
        /// ``ClipItem/hash(selection:into:)``, which sorts — so a re-copy landing
        /// here may lead with a different file, and ``backfillFiles(from:into:)``
        /// has already written that new order. Keeping the old icons would leave the front
        /// layer picturing the file the row used to lead with, which is the
        /// defect ``FileIconStack/icons(forFilesAt:maximum:)`` refuses a partial
        /// stack to avoid. Clearing sends the row back to its preview and count
        /// badge, which that same doc calls the honest thing to show.
        ///
        /// Nothing else can arrive as nil here. ``ThumbnailRenderer`` also
        /// answers nil for an entry holding one file or none, but such a capture
        /// cannot reach an existing stacked row: ``ClipItem/hash(kind:text:payload:fileURLs:)``
        /// takes the selection branch only above one file, so a lone file and a
        /// selection hash by different rules and never de-duplicate onto each
        /// other.
        private func backfillStack(_ icons: [Data]?, into record: ClipRecord) {
            record.stackIcons = icons
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
