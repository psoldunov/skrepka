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

    public init(
        contentHash: String,
        preview: String,
        kind: String,
        isPinned: Bool,
        createdAt: Date,
        byteCount: Int?,
        representations: [String]
    ) {
        self.contentHash = contentHash
        self.preview = preview
        self.kind = kind
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.byteCount = byteCount
        self.representations = representations
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
