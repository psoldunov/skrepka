import Foundation

/// One history entry, as a client sees it.
///
/// Metadata only. The bytes stay in the daemon: a menu, a list and a peer
/// picker all want a line of text and a size, and putting a 30 MB image on the
/// session bus so a client can decide not to draw it is the wrong default.
/// ``SkrepkaInterface/Member/copy`` is how a client acts on one.
public struct ClipDocument: Codable, Sendable, Hashable {
    /// SHA-256 over the content, lowercase hex. The identity of a clip
    /// everywhere in Skrepka, and what ``ClipSelector`` resolves against.
    public let contentHash: String

    /// One line, already flattened — newlines collapsed to spaces by the
    /// daemon, so every client renders the same string rather than each
    /// inventing its own truncation.
    public let preview: String

    /// `text`, `image`, `file`, `selection`, or whatever a later build adds.
    /// A string rather than an enum with a closed set, because a client that
    /// has never heard of a kind should still list the entry.
    public let kind: String

    public let isPinned: Bool
    public let createdAt: Date

    /// Bytes across every representation held, or nil where the daemon does not
    /// track it for this entry.
    public let byteCount: Int?

    /// The canonical media types held for this entry, sorted. What a client
    /// needs to decide whether it can do anything useful with a `Copy`.
    public let representations: [String]

    // MARK: Row details, since version 3
    //
    // A document from an older daemon carries none of these keys, and a client
    // reads each missing one as "not known" rather than failing the decode: nil
    // for the counts and sizes, false for the two flags — see
    // ``init(from:)``. What a picker row says under its title — "Text · 3
    // lines", "Image · 1402 × 578", "3 Files" — comes from these, and from
    // ``kind`` and ``byteCount``.

    /// Lines in the entry's text, for the "3 lines" a multi-line row shows.
    /// Nil where there is no text worth counting — a picture, a concealed
    /// entry — and from a daemon older than version 3.
    public let lineCount: Int?

    /// The picture's size in pixels, when the entry is one.
    public let imageWidth: Int?
    public let imageHeight: Int?

    /// Files a file entry holds — 3 for a copy of three files. Nil or 0 for
    /// anything that is not a file.
    public let fileCount: Int?

    /// Whether the entry came from a password manager. Its ``preview`` is
    /// already masked; this is what lets a client say so rather than draw a
    /// row of bullets with no explanation.
    public let isConcealed: Bool

    /// Whether ``SkrepkaInterface/Member/preview`` has a picture to answer
    /// with for this entry — the flag a client reads before asking, so a text
    /// row never costs a round trip.
    public let hasPreview: Bool

    public init(
        contentHash: String,
        preview: String,
        kind: String,
        isPinned: Bool,
        createdAt: Date,
        byteCount: Int?,
        representations: [String],
        lineCount: Int? = nil,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        fileCount: Int? = nil,
        isConcealed: Bool = false,
        hasPreview: Bool = false
    ) {
        self.contentHash = contentHash
        self.preview = preview
        self.kind = kind
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.representations = representations
        self.lineCount = lineCount
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fileCount = fileCount
        self.isConcealed = isConcealed
        self.hasPreview = hasPreview
    }

    private enum CodingKeys: String, CodingKey {
        case contentHash, preview, kind, isPinned, createdAt, byteCount, representations
        case lineCount, imageWidth, imageHeight, fileCount, isConcealed, hasPreview
    }

    /// Written out rather than synthesised for the two flags alone: a
    /// synthesised decoder requires every non-optional key, and a document
    /// from a version-2 daemon has neither. Everything else decodes exactly as
    /// the synthesised one would.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        preview = try container.decode(String.self, forKey: .preview)
        kind = try container.decode(String.self, forKey: .kind)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        representations = try container.decode([String].self, forKey: .representations)
        lineCount = try container.decodeIfPresent(Int.self, forKey: .lineCount)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
        isConcealed = try container.decodeIfPresent(Bool.self, forKey: .isConcealed) ?? false
        hasPreview = try container.decodeIfPresent(Bool.self, forKey: .hasPreview) ?? false
    }
}

/// The answer to ``SkrepkaInterface/Member/history``.
///
/// Ordered newest first with pinned entries hoisted — the same
/// `ClipProjection` order the macOS picker draws, applied in the daemon rather
/// than in each client, so a GNOME menu and `skrepka list` agree.
public struct HistoryDocument: SkrepkaDocument, Hashable {
    public let version: UInt32
    public let clips: [ClipDocument]

    /// Entries the store holds, which is not `clips.count` when the caller
    /// passed a limit. What lets a menu say "showing 20 of 400".
    public let total: Int

    public init(clips: [ClipDocument], total: Int, version: UInt32 = SkrepkaInterface.version) {
        self.version = version
        self.clips = clips
        self.total = total
    }
}
