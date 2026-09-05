import Foundation

/// A history row without its payload, and without its picture.
///
/// The store holds one of these per entry the retention cap allows and the
/// picker draws about twenty, so a summary carries only what a row needs to be
/// listed, ranked and measured. The full ``ClipPayload`` of an image entry can
/// be tens of megabytes and stays in the store until the entry is pasted; the
/// thumbnail is smaller but there is one per picture, so it stays there too and
/// is read by id when a row draws. ``hasThumbnail`` is the part the list needs —
/// it decides the row's height and whether to ask for the bytes at all.
public struct ClipSummary: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let kind: ClipKind
    public let text: String
    public let sourceBundleID: String?
    public let createdAt: Date
    public let isPinned: Bool
    public let isConcealed: Bool
    public let imageSize: ClipItem.ImageSize?
    /// Whether the store holds a rendered preview for this entry.
    ///
    /// Not the same question as "is this an image": an entry learned from a peer
    /// carries the picture's dimensions and none of its bytes, so it has an
    /// ``imageSize`` and no thumbnail.
    public let hasThumbnail: Bool

    public init(
        id: UUID,
        kind: ClipKind,
        text: String,
        sourceBundleID: String?,
        createdAt: Date,
        isPinned: Bool,
        isConcealed: Bool,
        imageSize: ClipItem.ImageSize?,
        hasThumbnail: Bool
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.imageSize = imageSize
        self.hasThumbnail = hasThumbnail
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

    /// Whether this entry is a picture, for counting and for anything that
    /// treats pictures as a group.
    ///
    /// Not `kind == .image`: `public.file-url` outranks `public.png` in
    /// ``PasteboardType/readOrder``, so a screenshot copied out of Finder is
    /// `.file`, and counting by kind alone reported zero Images for a history
    /// full of them. Not ``ClipKind/canPreview`` either — that admits every
    /// `.file`, so a copied text document would count. A thumbnail is the
    /// honest signal: one exists only where something decoded to a picture.
    public var isPicture: Bool {
        kind == .image || hasThumbnail
    }
}
