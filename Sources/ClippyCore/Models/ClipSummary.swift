import Foundation

/// A history row without its payload.
///
/// The picker holds hundreds of these; the full ``ClipPayload`` of an image
/// entry can be tens of megabytes, so payloads stay in the store until an entry
/// is actually pasted. The thumbnail is small enough to carry inline.
public struct ClipSummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let kind: ClipKind
    public let text: String
    public let sourceBundleID: String?
    public let createdAt: Date
    public let isPinned: Bool
    public let isConcealed: Bool
    public let imageSize: ClipItem.ImageSize?
    /// Small PNG rendering for image entries.
    public let thumbnail: Data?

    public init(
        id: UUID,
        kind: ClipKind,
        text: String,
        sourceBundleID: String?,
        createdAt: Date,
        isPinned: Bool,
        isConcealed: Bool,
        imageSize: ClipItem.ImageSize?,
        thumbnail: Data?
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.imageSize = imageSize
        self.thumbnail = thumbnail
    }

    /// Single-line preview, masked when the entry came from a password manager.
    ///
    /// An image has no text to collapse, so it is labelled by its dimensions.
    public var previewText: String {
        guard !isConcealed else { return PreviewText.concealedMask }
        if let collapsed = PreviewText.collapsed(text) { return collapsed }
        if kind == .image, let imageSize { return imageSize.description }
        return kind.displayName
    }

    /// Line count of the original text, shown as "+3 lines" on multi-line rows.
    public var lineCount: Int {
        guard !isConcealed else { return 1 }
        return max(1, text.split(whereSeparator: \.isNewline).count)
    }
}
