import Foundation
import SwiftData

/// The persisted shape of a history entry.
///
/// Deliberately thin — persistence only, no behaviour. `ClipRecord` is mapped
/// to ``ClipSummary`` (for the list) or ``ClipPayload`` (on paste) at the store
/// boundary, so nothing outside `Store/` handles a SwiftData object.
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
    var byteCount: Int?
    /// Small PNG preview. Inline: it is read for every visible row.
    var thumbnailData: Data?
    /// Absolute URL of every file the entry holds, when it holds files.
    ///
    /// The payload carries the first one and no more — see ``ClipItem/fileURLs``
    /// — so this is what lets a copy of several files paste back as several
    /// files. Optional with no default, so a store written before multi-file
    /// copies were kept migrates by leaving it nil rather than claiming every
    /// old entry holds no files at all.
    var fileURLStrings: [String]?
    /// Every pasteboard representation, property-list encoded.
    ///
    /// `.externalStorage` keeps the blob out of the SQLite row, so a 20 MB
    /// screenshot lands in `_EXTERNAL_DATA/` rather than bloating the table.
    @Attribute(.externalStorage) var payloadData: Data = Data()

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
        fileURLStrings: [String]?,
        payloadData: Data
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
        self.fileURLStrings = fileURLStrings
        self.payloadData = payloadData
    }
}
