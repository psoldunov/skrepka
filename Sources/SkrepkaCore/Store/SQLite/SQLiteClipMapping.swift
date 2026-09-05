// Raw SQLite is the Linux persistence engine (D-3); macOS never resolves the
// CSQLite target, so every file in this directory is fenced to Linux.
#if os(Linux)

    import Foundation
    import SkrepkaSync

    /// Conversions between ``SQLiteClipRow`` and the value types the rest of the
    /// app and the wire use.
    ///
    /// **Each conformance owns its own mapping** — `ClipRecordMapping` and
    /// `SyncMetaMapping` belong to the SwiftData store, this belongs to the SQLite
    /// one, and `docs/linux-sync/phase-4-core-on-linux.md` names that duplication
    /// as a cost of two engines rather than an accident. The two are held in step
    /// by `HistoryStoringTests` running against both, and every rule stated in
    /// `SyncMetaMapping` is restated here on purpose rather than by reference: a
    /// reader changing one has to be told the other exists.
    enum SQLiteClipMapping {
        static func summary(from row: SQLiteClipRow) -> ClipSummary {
            let imageSize: ClipItem.ImageSize? =
                if let width = row.imageWidth, let height = row.imageHeight {
                    ClipItem.ImageSize(width: width, height: height)
                } else {
                    nil
                }
            return ClipSummary(
                id: row.id,
                kind: ClipKind(rawValue: row.kindRaw) ?? .text,
                text: row.text,
                sourceBundleID: row.sourceBundleID,
                createdAt: row.createdAt,
                isPinned: row.isPinned,
                isConcealed: row.isConcealed,
                imageSize: imageSize,
                hasThumbnail: row.thumbnail != nil
            )
        }

        /// Describes a row to a peer.
        ///
        /// - Parameters:
        ///   - representations: the row's representation index, already read.
        ///   - localDeviceID: stands in wherever the row names no device. A row
        ///     captured before this machine had a sync identity has no origin and
        ///     no pin author, and this machine is the only honest answer for both:
        ///     it is the one holding the content.
        static func meta(
            from row: SQLiteClipRow,
            representations: [String: Int],
            localDeviceID: SyncDeviceID
        ) -> SyncClipMeta {
            SyncClipMeta(
                contentHash: row.contentHash,
                kind: row.kindRaw,
                preview: row.text,
                createdAt: row.createdAt,
                isPinned: pinRegister(from: row, localDeviceID: localDeviceID),
                isConcealed: row.isConcealed,
                imageWidth: row.imageWidth,
                imageHeight: row.imageHeight,
                sourceBundleID: row.sourceBundleID,
                originDeviceID: deviceID(row.originDeviceID) ?? localDeviceID,
                representations: descriptors(from: representations)
            )
        }

        /// The pin as a last-writer-wins register.
        ///
        /// A row pinned before the register existed carries no `pinned_at` and
        /// falls back to `created_at`, which biases an old pin to lose against a
        /// peer's explicit write. That is the right direction — the peer's write is
        /// newer information — and reading the clock here instead would make the
        /// register's timestamp depend on when the index happened to be built.
        static func pinRegister(
            from row: SQLiteClipRow,
            localDeviceID: SyncDeviceID
        ) -> LWWRegister<Bool> {
            LWWRegister(
                value: row.isPinned,
                timestamp: row.pinnedAt ?? row.createdAt,
                deviceID: deviceID(row.pinnedBy) ?? localDeviceID
            )
        }

        /// Representation index to wire descriptors.
        ///
        /// A local type with no canonical media type is dropped rather than
        /// invented — `com.apple.flat-rtfd` is the case that matters, and
        /// `RepresentationKeyMap.unmappableUTIs` says why.
        static func descriptors(from index: [String: Int]) -> [RepresentationDescriptor] {
            index.compactMap { type, byteCount in
                RepresentationKeyMap.key(forUTI: type)
                    .map { RepresentationDescriptor(key: $0, byteCount: byteCount) }
            }
            .sorted()
        }

        /// Parses a stored identifier, tolerating one that is not a device id.
        ///
        /// `SyncDeviceID.init(hex:)` refuses anything that is not 64 lowercase hex
        /// characters, and a column can hold whatever an older build or a corrupt
        /// row put there. Callers substitute the local device.
        static func deviceID(_ hex: String?) -> SyncDeviceID? {
            hex.flatMap(SyncDeviceID.init(hex:))
        }
    }

#endif
