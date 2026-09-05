// Maps the SwiftData ClipRecord, so it belongs to that conformance. The Linux
// SQLite store writes its own mapping in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync

    /// Conversions between the persisted ``ClipRecord`` and the `SkrepkaSync`
    /// value type a peer is offered. Kept out of `ClipRecord` so the model stays a
    /// shape, exactly as ``ClipRecordMapping`` is.
    enum SyncMetaMapping {
        /// Describes a row to a peer.
        ///
        /// - Parameters:
        ///   - representations: the row's representation index, already decoded —
        ///     the caller owns that read because it also owns the backfill of rows
        ///     written before the column existed.
        ///   - localDeviceID: stands in wherever the row names no device. A row
        ///     captured before sync existed has no origin and no pin author, and
        ///     this machine is the only honest answer for both: it is the one
        ///     holding the content.
        static func meta(
            from record: ClipRecord,
            representations: [String: Int],
            localDeviceID: SyncDeviceID
        ) -> SyncClipMeta {
            SyncClipMeta(
                contentHash: record.contentHash,
                kind: record.kindRaw,
                preview: record.text,
                createdAt: record.createdAt,
                isPinned: pinRegister(from: record, localDeviceID: localDeviceID),
                isConcealed: record.isConcealed,
                imageWidth: record.imageWidth,
                imageHeight: record.imageHeight,
                sourceBundleID: record.sourceBundleID,
                originDeviceID: deviceID(record.originDeviceID) ?? localDeviceID,
                representations: descriptors(from: representations)
            )
        }

        /// Builds a row for content learned from a peer.
        ///
        /// ``ClipRecord/payloadData`` is left empty on purpose: metadata is eager
        /// and payload is lazy (design §7), so the bytes arrive later on a fetch
        /// the transport decides to make. The representation index is written
        /// anyway — it is what tells the fetch what there is to ask for.
        ///
        /// `id` is generated locally. Identity across machines is `contentHash`,
        /// never `id`; a `UUID` from a peer would be a second identity for the
        /// same content.
        static func makeRecord(from meta: SyncClipMeta) throws -> ClipRecord {
            ClipRecord(
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
                // Nil rather than defaulted, so the reason is at the call site:
                // a size measures the copied thing on the machine that copied
                // it, and none crosses the wire — see ``SkrepkaSync/SyncClipMeta``.
                byteCount: nil,
                thumbnailData: nil,
                payloadData: Data(),
                pinnedAt: meta.isPinned.timestamp,
                pinnedBy: meta.isPinned.deviceID.hex,
                originDeviceID: meta.originDeviceID.hex,
                representationIndex: try RepresentationIndex.encode(index(from: meta.representations))
            )
        }

        /// The pin as a last-writer-wins register.
        ///
        /// A row pinned before this schema existed carries no ``ClipRecord/pinnedAt``
        /// and falls back to ``ClipRecord/createdAt``. That biases an old pin to
        /// lose against any peer's explicit write, which is the right direction:
        /// the peer's write is newer information, and the alternative — reading the
        /// clock here — would make the register's timestamp depend on when the
        /// index happened to be built.
        static func pinRegister(from record: ClipRecord, localDeviceID: SyncDeviceID) -> LWWRegister<Bool> {
            LWWRegister(
                value: record.isPinned,
                timestamp: record.pinnedAt ?? record.createdAt,
                deviceID: deviceID(record.pinnedBy) ?? localDeviceID
            )
        }

        /// Representation index to wire descriptors.
        ///
        /// A pasteboard type with no canonical media type is dropped rather than
        /// invented — `com.apple.flat-rtfd` is the case that matters, and
        /// `RepresentationKeyMap.unmappableUTIs` says why. Offering it under a
        /// made-up name would have a peer fetch bytes it cannot read.
        static func descriptors(from index: [String: Int]) -> [RepresentationDescriptor] {
            index.compactMap { uti, byteCount in
                RepresentationKeyMap.key(forUTI: uti)
                    .map { RepresentationDescriptor(key: $0, byteCount: byteCount) }
            }
            .sorted()
        }

        /// Wire descriptors back to a representation index.
        ///
        /// Keyed by the *local* pasteboard type, derived from the canonical media
        /// type rather than from `RepresentationKey.origin`: the origin may be a
        /// Linux MIME target, and a macOS store indexing itself by one would name
        /// a type no pasteboard here can serve.
        static func index(from descriptors: [RepresentationDescriptor]) -> [String: Int] {
            var result: [String: Int] = [:]
            for descriptor in descriptors {
                guard let uti = RepresentationKeyMap.uti(forCanonical: descriptor.key.canonical) else {
                    continue
                }
                result[uti] = descriptor.byteCount
            }
            return result
        }

        /// Parses a stored identifier, tolerating one that is not a device id.
        ///
        /// `SyncDeviceID.init(hex:)` refuses anything that is not 64 lowercase hex
        /// characters, and a column can hold whatever an older build or a corrupt
        /// row put there. Callers substitute the local device.
        private static func deviceID(_ hex: String?) -> SyncDeviceID? {
            hex.flatMap(SyncDeviceID.init(hex:))
        }
    }

#endif
