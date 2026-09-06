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
    /// Size of the copied content, when one could be measured.
    ///
    /// Measured on the machine that made the copy and never sent to a peer — a
    /// file's size describes a path only that machine has. A row learned from a
    /// peer therefore has none, exactly as it has no thumbnail.
    public let byteCount: Int?
    /// How many files the entry holds — 3 for a copy of three files, 1 for a
    /// copy of one, and 0 for anything that is not a file.
    ///
    /// Zero also for a file entry stored before Skrepka kept more than the first
    /// file, which is why the row asks ``fileCount`` for a *count* and never for
    /// "is this a file": ``ClipKind/isFileSystemEntry`` answers that, and an old
    /// row still holds its one file whatever this says.
    public let fileCount: Int
    /// Whether the store holds a rendered preview for this entry.
    ///
    /// Not the same question as "is this an image": an entry learned from a peer
    /// carries the picture's dimensions and none of its bytes, so it has an
    /// ``imageSize`` and no thumbnail.
    public let hasThumbnail: Bool
    /// Whether the store holds a stack of file icons for this entry — one
    /// picture per file, for a row that holds several and draws them piled
    /// instead of previewing the first alone.
    ///
    /// A flag rather than the pictures, for the reason this whole type carries
    /// none: three icons on every file row is three pictures per row resident
    /// for as long as the summary is, and file rows are the ones a "select all,
    /// copy" habit makes numerous. The bytes are read by id when a row draws —
    /// see `ThumbnailCache`.
    ///
    /// False for a row stored before stacks existed, and false on Linux, where
    /// nothing can render one yet.
    public let hasStackIcons: Bool

    public init(
        id: UUID,
        kind: ClipKind,
        text: String,
        sourceBundleID: String?,
        createdAt: Date,
        isPinned: Bool,
        isConcealed: Bool,
        imageSize: ClipItem.ImageSize?,
        byteCount: Int?,
        fileCount: Int = 0,
        hasThumbnail: Bool,
        hasStackIcons: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.imageSize = imageSize
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.hasThumbnail = hasThumbnail
        self.hasStackIcons = hasStackIcons
    }

    /// The content's size as the row subtitle shows it, or nil when there is
    /// nothing to show.
    ///
    /// Decimal units, matching what Finder reports for the same file: the
    /// `.file` style counts a kilobyte as 1000 bytes, so a row and Get Info do
    /// not disagree about the same file.
    ///
    /// Withheld from a concealed entry along with everything else about it. A
    /// password manager's payload is text and gets no size anyway, but the rule
    /// belongs with the other one rather than resting on that.
    ///
    /// - Parameter locale: defaults to the user's, which is what the picker
    ///   wants — a French Mac says `1,5 Mo` where an American one says
    ///   `1.5 MB`. Named so tests can pin one; asserting against the machine's
    ///   locale is a test that passes in Cupertino and fails in Zurich.
    public func sizeText(locale: Locale = .autoupdatingCurrent) -> String? {
        guard !isConcealed, let byteCount else { return nil }
        return byteCount.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    /// Single-line preview, masked when the entry came from a password manager.
    ///
    /// An image has no text to collapse, so it is labelled by its dimensions.
    ///
    /// A copy of several files is a list of names, and a list wants commas: the
    /// plain collapse joins lines with spaces, which ran three file names into
    /// one long string that read like a single absurd file name.
    public var previewText: String {
        guard !isConcealed else { return PreviewText.concealedMask }
        let separator = kind.isFileSystemEntry ? ", " : " "
        if let collapsed = PreviewText.collapsed(text, separator: separator) { return collapsed }
        if kind == .image, let imageSize { return imageSize.description }
        return kind.displayName
    }

    /// What the row calls this entry: "Image", or "3 Images" when it holds
    /// several files.
    ///
    /// Counted from ``fileCount`` rather than from the lines of ``text``, so a
    /// row only ever claims files it can actually paste back.
    public var typeLabel: String {
        guard kind.isFileSystemEntry, fileCount > 1 else { return kind.displayName }
        return "\(fileCount) \(kind.pluralDisplayName)"
    }

    /// Line count of the original text, shown as "3 lines" on multi-line rows.
    public var lineCount: Int {
        guard !isConcealed else { return 1 }
        return max(1, text.split(whereSeparator: \.isNewline).count)
    }

    /// The "3 lines" a row shows, or nil when there is nothing worth saying.
    ///
    /// A file entry never has one. Its text is a list of file names, so counting
    /// lines counts files — and it counted them from names the pasteboard
    /// supplied rather than from files Skrepka kept, which is how a copy of
    /// three pictures came to read "1402 × 578 · 3 lines" while holding one.
    /// ``typeLabel`` says it properly.
    public var lineCountText: String? {
        guard !kind.isFileSystemEntry, lineCount > 1 else { return nil }
        return "\(lineCount) lines"
    }

    /// The `1402 × 578` a row shows, or nil when no single picture is being
    /// described — a selection of several files is previewed by its first, and
    /// labelling the row with that one's dimensions describes the other two.
    public var imageSizeText: String? {
        guard !isConcealed, fileCount <= 1, let imageSize else { return nil }
        return imageSize.description
    }

    /// Whether this entry is a picture, for counting and for anything that
    /// treats pictures as a group.
    ///
    /// Not the image kinds alone: a picture whose file the disk would not
    /// describe stays a `.file`, and counting by kind alone reported zero Images
    /// for a history full of them. Not ``ClipKind/canPreview`` either — that
    /// admits every `.file`, so a copied text document would count. A thumbnail
    /// is the honest signal for the rest: one exists only where something
    /// decoded to a picture.
    public var isPicture: Bool {
        kind == .image || kind == .imageFile || hasThumbnail
    }
}
