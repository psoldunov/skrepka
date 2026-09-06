// Maps the SwiftData ClipRecord, so it belongs to that conformance. The Linux
// SQLite store writes its own mapping in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation

    /// Conversions between the persisted ``ClipRecord`` and the value types the
    /// rest of the app uses. Kept out of `ClipRecord` so the model stays a shape.
    enum ClipRecordMapping {
        private static let encoder: PropertyListEncoder = {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return encoder
        }()

        static func encode(_ payload: ClipPayload) throws -> Data {
            try encoder.encode(payload.representations)
        }

        static func decodePayload(_ data: Data) throws -> ClipPayload {
            guard !data.isEmpty else { return ClipPayload(representations: [:]) }
            let representations = try PropertyListDecoder().decode([String: Data].self, from: data)
            return ClipPayload(representations: representations)
        }

        /// - Parameters:
        ///   - details: what the off-actor detail pass read off the copied content
        ///     — see ``ThumbnailRenderer``.
        ///   - originDeviceID: `SyncDeviceID.hex` of this machine, or `nil` when it
        ///     has no sync identity yet.
        static func makeRecord(
            from item: ClipItem,
            details: ClipDetails,
            originDeviceID: String? = nil
        ) throws -> ClipRecord {
            // The pixel size comes from decoding the image, which only the preview
            // step does — the capture rules never touch AppKit imaging.
            let imageSize = details.preview?.pixelSize ?? item.imageSize
            return ClipRecord(
                id: item.id,
                // The capture rules call every file URL a `.file`; only the detail
                // pass can say it is a folder, and only when the disk answered.
                kindRaw: (details.kind ?? item.kind).rawValue,
                text: item.text,
                sourceBundleID: item.sourceBundleID,
                createdAt: item.createdAt,
                isPinned: item.isPinned,
                isConcealed: item.isConcealed,
                contentHash: item.contentHash,
                imageWidth: imageSize?.width,
                imageHeight: imageSize?.height,
                byteCount: details.byteCount,
                thumbnailData: details.preview?.thumbnail,
                stackIcons: details.stackIcons,
                // Nil rather than an empty array for an entry that holds no files,
                // so "this copy had none" and "this row predates the column" read
                // the same way: as nothing to paste back beyond the payload.
                fileURLStrings: item.fileURLs.isEmpty ? nil : item.fileURLs.map(\.absoluteString),
                payloadData: try encode(item.payload),
                // Written here, in the one place a row is created from a capture,
                // so it cannot be forgotten: it describes the payload beside it and
                // the two must never disagree. See ``RepresentationIndex``.
                originDeviceID: originDeviceID,
                representationIndex: try RepresentationIndex.encode(
                    RepresentationIndex.make(from: item.payload)
                )
            )
        }

        static func summary(from record: ClipRecord) -> ClipSummary {
            let imageSize: ClipItem.ImageSize? =
                if let width = record.imageWidth, let height = record.imageHeight {
                    ClipItem.ImageSize(width: width, height: height)
                } else {
                    nil
                }
            return ClipSummary(
                id: record.id,
                kind: ClipKind(rawValue: record.kindRaw) ?? .text,
                text: record.text,
                sourceBundleID: record.sourceBundleID,
                createdAt: record.createdAt,
                isPinned: record.isPinned,
                isConcealed: record.isConcealed,
                imageSize: imageSize,
                byteCount: record.byteCount,
                // The count, not the URLs: the picker holds hundreds of these and
                // needs only to say "3 Files". The list itself stays in the store
                // until something is pasted, like the payload beside it.
                fileCount: record.fileURLStrings?.count ?? 0,
                hasThumbnail: record.thumbnailData != nil,
                // Whether, not which: the pictures are read by id when the row
                // draws, for the reason the thumbnail beside them is.
                hasStackIcons: !(record.stackIcons ?? []).isEmpty
            )
        }

        /// The files an entry holds, for the paste that restores them.
        static func fileURLs(from record: ClipRecord) -> [URL] {
            (record.fileURLStrings ?? []).compactMap(URL.init(string:))
        }
    }

#endif
