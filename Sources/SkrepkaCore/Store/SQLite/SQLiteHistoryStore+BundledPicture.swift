// A synced image file, told apart from any other file by the picture its
// bundle holds. Fenced to Linux with the rest of this directory (D-3).
#if os(Linux)

    import Foundation
    import SkrepkaSync

    extension SQLiteHistoryStore {
        /// Marks a file row as an image file, with the picture's dimensions,
        /// when the bytes that just arrived hold one picture and nothing else.
        ///
        /// The Linux counterpart of the Mac store rendering a thumbnail from the
        /// bundle: there is no image decoder here yet (D-9, Phase 7), but the
        /// header says how large the picture is, and the kind says it is one.
        /// Dimensions a row already knows are kept. Caller owns the transaction.
        func recordBundledPicture(of meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws {
            guard meta.kind == ClipKind.file.rawValue || meta.kind == ClipKind.imageFile.rawValue,
                let picture = ForeignFileGuard.picture(in: RepresentationKeyMap.utiKeyed(payloads))
            else { return }
            let size = picture.type.pixelSize(of: picture.bytes)
            try database.run(
                """
                UPDATE clip SET kind_raw = ?,
                    image_width = COALESCE(image_width, ?),
                    image_height = COALESCE(image_height, ?)
                WHERE content_hash = ?
                """,
                [
                    .value(ClipKind.imageFile.rawValue),
                    .value(size?.width),
                    .value(size?.height),
                    .value(meta.contentHash),
                ]
            )
        }
    }

#endif
