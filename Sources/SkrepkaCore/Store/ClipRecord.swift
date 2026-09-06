// SwiftData is the macOS persistence engine and stays that way (D-3, D-9). Linux
// gets a separate SQLite conformance of HistoryStoring in Phase 4 storage work,
// not a second @Model.
#if canImport(SwiftData)

    import Foundation
    import SwiftData

    /// The persisted shape of a history entry.
    ///
    /// Deliberately thin — persistence only, no behaviour. `ClipRecord` is mapped
    /// to ``ClipSummary`` (for the list) or ``ClipPayload`` (on paste) at the store
    /// boundary, so nothing outside `Store/` handles a SwiftData object.
    ///
    /// The sync properties are all optional. That is what makes adding them a
    /// lightweight migration on macOS 26 rather than a `SchemaMigrationPlan` —
    /// measured against a populated throwaway store, recorded as OQ-9.
    @Model
    final class ClipRecord {
        var id: UUID = UUID()
        var kindRaw: String = ClipKind.text.rawValue
        var text: String = ""
        var sourceBundleID: String?
        var createdAt: Date = Date()
        var isPinned: Bool = false
        var isConcealed: Bool = false
        var contentHash: String = ""
        var imageWidth: Int?
        var imageHeight: Int?
        /// Size of the copied content, when one could be measured. Optional with no
        /// default, so a store written before sizes existed migrates by leaving it
        /// nil rather than claiming every old entry is zero bytes.
        ///
        /// Local to this machine and deliberately not synced: a file's size
        /// describes a path only the machine that copied it has — see
        /// ``SkrepkaSync/SyncClipMeta``.
        var byteCount: Int?
        /// Small PNG preview. Inline: it is read for every visible row.
        var thumbnailData: Data?
        /// Every pasteboard representation, property-list encoded.
        ///
        /// `.externalStorage` keeps the blob out of the SQLite row, so a 20 MB
        /// screenshot lands in `_EXTERNAL_DATA/` rather than bloating the table.
        @Attribute(.externalStorage) var payloadData: Data = Data()

        // MARK: - Sync

        /// When the pin was last written — the timestamp half of the pin's
        /// last-writer-wins register. `nil` on a row pinned before sync existed;
        /// ``SyncMetaMapping`` falls back to ``createdAt`` for those.
        var pinnedAt: Date?
        /// `SyncDeviceID.hex` of whoever last wrote the pin, for the register's
        /// tie-break. Stored as a string because `SyncDeviceID` is a `SkrepkaSync`
        /// value type and this row is a persistence shape.
        var pinnedBy: String?
        /// `SyncDeviceID.hex` of the device that first captured this content. A
        /// label, never an authority — merges do not consult it.
        var originDeviceID: String?
        /// Property-list encoded `[String: Int]`: representation byte counts keyed
        /// by pasteboard type. Denormalised out of ``payloadData`` — see
        /// ``RepresentationIndex``.
        ///
        /// It records what the content *has*, not what this machine *holds*, so
        /// an index offer filters it against the payload before advertising it:
        /// a row learned from a peer carries the full claim while holding none
        /// of the bytes, and offering that claim onward would have a peer fetch
        /// what this device cannot serve. That filter is the one external-storage
        /// read this field was denormalised to avoid, and it is paid only by rows
        /// that actually hold bytes.
        var representationIndex: Data?

        init(
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
            byteCount: Int?,
            thumbnailData: Data?,
            payloadData: Data,
            pinnedAt: Date? = nil,
            pinnedBy: String? = nil,
            originDeviceID: String? = nil,
            representationIndex: Data? = nil
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
            self.byteCount = byteCount
            self.thumbnailData = thumbnailData
            self.payloadData = payloadData
            self.pinnedAt = pinnedAt
            self.pinnedBy = pinnedBy
            self.originDeviceID = originDeviceID
            self.representationIndex = representationIndex
        }
    }

#endif
