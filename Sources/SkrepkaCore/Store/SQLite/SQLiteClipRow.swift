// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation
    import SkrepkaSync

    /// One row of the `clip` table.
    ///
    /// The Linux counterpart of `ClipRecord`, and thin for the same reason:
    /// persistence shape only, mapped to a value type at the store boundary by
    /// ``SQLiteClipMapping``. A `struct` rather than a class because nothing here
    /// has identity to share — the row is a snapshot, and the database is the
    /// object.
    struct SQLiteClipRow: Sendable, Equatable {
        let id: UUID
        let kindRaw: String
        let text: String
        let sourceBundleID: String?
        let createdAt: Date
        let isPinned: Bool
        let isConcealed: Bool
        let contentHash: String
        let imageWidth: Int?
        let imageHeight: Int?
        /// `ClipRecord.byteCount` — the size of the copied thing, measured where
        /// it was copied. Always nil today: measuring it needs the detail pass,
        /// which is AppKit and arrives here with the preview in Phase 7.
        let contentByteCount: Int?
        let thumbnail: Data?
        let pinnedAt: Date?
        let pinnedBy: String?
        let originDeviceID: String?

        /// The column list every `SELECT` in this store uses, so the order the
        /// reader below assumes cannot drift away from the order the queries ask
        /// for.
        static let columns = """
            id, kind_raw, "text", source_bundle_id, created_at, is_pinned, is_concealed, \
            content_hash, image_width, image_height, content_byte_count, thumbnail, pinned_at, \
            pinned_by, origin_device_id
            """

        static let insert = """
            INSERT INTO clip (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        /// Parameters for ``insert``, in its column order.
        var bindings: [SQLiteValue] {
            [
                .value(id),
                .value(kindRaw),
                .value(text),
                .value(sourceBundleID),
                .value(createdAt),
                .value(isPinned),
                .value(isConcealed),
                .value(contentHash),
                .value(imageWidth),
                .value(imageHeight),
                .value(contentByteCount),
                .value(thumbnail),
                .value(pinnedAt),
                .value(pinnedBy),
                .value(originDeviceID),
            ]
        }

        /// Reads the row the statement is currently on.
        ///
        /// `nil` when a column the schema declares `NOT NULL` will not read as its
        /// Swift type — a row whose `id` is not a `UUID` cannot be named, pinned or
        /// deleted, so returning it would be worse than skipping it. Callers log
        /// and move on, the same way `TombstoneRecordMapping` treats a device
        /// identifier it cannot parse.
        init?(statement: SQLiteStatement) {
            guard let idText = statement.text(0),
                let id = UUID(uuidString: idText),
                let kindRaw = statement.text(1),
                let text = statement.text(2),
                let createdAt = statement.date(4),
                let contentHash = statement.text(7)
            else { return nil }

            self.id = id
            self.kindRaw = kindRaw
            self.text = text
            sourceBundleID = statement.text(3)
            self.createdAt = createdAt
            isPinned = statement.bool(5)
            isConcealed = statement.bool(6)
            self.contentHash = contentHash
            imageWidth = statement.integer(8)
            imageHeight = statement.integer(9)
            contentByteCount = statement.integer(10)
            thumbnail = statement.blob(11)
            pinnedAt = statement.date(12)
            pinnedBy = statement.text(13)
            originDeviceID = statement.text(14)
        }

        private init(
            id: UUID,
            kindRaw: String,
            text: String,
            sourceBundleID: String?,
            createdAt: Date,
            isPinned: Bool,
            isConcealed: Bool,
            contentHash: String,
            imageWidth: Int?,
            imageHeight: Int?,
            contentByteCount: Int?,
            thumbnail: Data?,
            pinnedAt: Date?,
            pinnedBy: String?,
            originDeviceID: String?
        ) {
            self.id = id
            self.kindRaw = kindRaw
            self.text = text
            self.sourceBundleID = sourceBundleID
            self.createdAt = createdAt
            self.isPinned = isPinned
            self.isConcealed = isConcealed
            self.contentHash = contentHash
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.contentByteCount = contentByteCount
            self.thumbnail = thumbnail
            self.pinnedAt = pinnedAt
            self.pinnedBy = pinnedBy
            self.originDeviceID = originDeviceID
        }

        /// A row for something copied on this machine.
        ///
        /// `thumbnail` is always nil: rendering one needs `ThumbnailMaker`, which
        /// is AppKit, and D-9 defers `ThumbnailProducing` to Phase 7 rather than
        /// giving macOS a protocol with a nil-returning stub behind it. A Linux row
        /// gets its preview when GdkPixbuf arrives.
        static func make(from item: ClipItem, originDeviceID: String?) -> SQLiteClipRow {
            SQLiteClipRow(
                id: item.id,
                kindRaw: item.kind.rawValue,
                text: item.text,
                sourceBundleID: item.sourceBundleID,
                createdAt: item.createdAt,
                isPinned: item.isPinned,
                isConcealed: item.isConcealed,
                contentHash: item.contentHash,
                imageWidth: item.imageSize?.width,
                imageHeight: item.imageSize?.height,
                contentByteCount: nil,
                thumbnail: nil,
                pinnedAt: nil,
                pinnedBy: nil,
                originDeviceID: originDeviceID
            )
        }

        /// A row for content learned from a peer.
        ///
        /// `id` is generated locally, exactly as `SyncMetaMapping.makeRecord`
        /// does: identity across machines is `contentHash`, and a `UUID` from a
        /// peer would be a second identity for the same content.
        static func make(from meta: SyncClipMeta) -> SQLiteClipRow {
            SQLiteClipRow(
                id: UUID(),
                kindRaw: meta.kind,
                text: meta.preview,
                sourceBundleID: meta.sourceBundleID,
                createdAt: meta.createdAt,
                isPinned: meta.isPinned.value,
                isConcealed: meta.isConcealed,
                contentHash: meta.contentHash,
                imageWidth: meta.imageWidth,
                imageHeight: meta.imageHeight,
                contentByteCount: nil,
                thumbnail: nil,
                pinnedAt: meta.isPinned.timestamp,
                pinnedBy: meta.isPinned.deviceID.hex,
                originDeviceID: meta.originDeviceID.hex
            )
        }
    }

#endif
