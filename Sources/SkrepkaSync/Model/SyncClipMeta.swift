import Foundation

/// One clipboard entry as a peer describes it — a few hundred bytes, and not
/// one byte of payload.
///
/// `kind` is a raw `String` rather than `SkrepkaCore.ClipKind` on purpose: this
/// target must build on Linux, where `SkrepkaCore` does not, so everything it
/// needs from the core crosses as a primitive.
///
/// **The content's size is deliberately not here.** A row shows one — see
/// `SkrepkaCore.ClipSummary.byteCount` — but for a file or a folder it is the
/// size of a path only the machine that made the copy has, and sending it would
/// have a peer display a measurement of something it cannot see. For an image
/// it would be a second, less precise copy of what ``representations`` already
/// carries per representation. A receiver measures what it holds or shows
/// nothing, which is the same rule it follows for a thumbnail.
public struct SyncClipMeta: Sendable, Hashable, Codable {
    /// Content identity. Two machines copying the same string converge on this
    /// and on nothing else — a locally generated `UUID` cannot.
    public let contentHash: String
    /// `ClipKind.rawValue`, carried as a string so this target stays free of
    /// `SkrepkaCore`.
    public let kind: String
    /// Plain-text rendering, capped at ``SyncLimits/previewByteLimit``.
    public let preview: String
    /// Normalised to millisecond precision — see
    /// ``WireTimestamp/millisecondPrecision(_:)``.
    public let createdAt: Date
    public let isPinned: LWWRegister<Bool>
    /// Set when the item carried a password-manager marker. Concealed content
    /// never crosses the wire at all; the flag is here so a receiver can carry
    /// it forward if a future version ever changes that.
    public let isConcealed: Bool
    public let imageWidth: Int?
    public let imageHeight: Int?
    /// Has no Linux analogue. Carried, displayed only where it means something.
    public let sourceBundleID: String?
    /// Which device first recorded this content. Not an authority over the
    /// item — it is a label, and merges never consult it.
    public let originDeviceID: SyncDeviceID
    /// Sorted, so two peers describing one item produce the same bytes.
    public let representations: [RepresentationDescriptor]

    public init(
        contentHash: String,
        kind: String,
        preview: String,
        createdAt: Date,
        isPinned: LWWRegister<Bool>,
        isConcealed: Bool = false,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil,
        sourceBundleID: String? = nil,
        originDeviceID: SyncDeviceID,
        representations: [RepresentationDescriptor] = []
    ) {
        self.contentHash = contentHash
        self.kind = kind
        self.preview = Self.capped(preview)
        self.createdAt = WireTimestamp.millisecondPrecision(createdAt)
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.sourceBundleID = sourceBundleID
        self.originDeviceID = originDeviceID
        self.representations = representations.sorted()
    }

    /// Truncates a preview to ``SyncLimits/previewByteLimit`` UTF-8 bytes on a
    /// character boundary.
    ///
    /// Cutting mid-scalar would produce a `String` that is not valid UTF-8,
    /// which is a decode failure on the far end rather than a shorter preview.
    static func capped(_ text: String) -> String {
        guard text.utf8.count > SyncLimits.previewByteLimit else { return text }
        var kept = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            guard used + width <= SyncLimits.previewByteLimit else { break }
            kept.append(character)
            used += width
        }
        return kept
    }

    /// Folds a second description of the same content into this one.
    ///
    /// Only ``createdAt`` and ``isPinned`` merge, because they are the only
    /// fields two peers may legitimately disagree about: `contentHash` identity
    /// means the bytes are the same bytes, so kind, preview and dimensions
    /// describe them equally well. Everything else is taken from whichever
    /// description ``preferredBase(_:)`` picks, so the fold is commutative and
    /// the result does not depend on the order two offers arrived in.
    ///
    /// Representation *lists* can legitimately differ — a Linux peer offers no
    /// `application/pdf` — and this deliberately does not union them: a list is
    /// a claim about what its owner can serve, and adopting a peer's claim
    /// would have the receiver offer bytes it does not have.
    ///
    /// Callers must pass a description of the same content; the receiver's
    /// ``contentHash`` is the one kept.
    public func combining(_ other: SyncClipMeta) -> SyncClipMeta {
        let base = preferredBase(other)
        return SyncClipMeta(
            contentHash: contentHash,
            kind: base.kind,
            preview: base.preview,
            createdAt: max(createdAt, other.createdAt),
            isPinned: isPinned.merged(with: other.isPinned),
            isConcealed: base.isConcealed,
            imageWidth: base.imageWidth,
            imageHeight: base.imageHeight,
            sourceBundleID: base.sourceBundleID,
            originDeviceID: base.originDeviceID,
            representations: base.representations
        )
    }

    /// Which of the two descriptions the fields that do not merge are taken
    /// from.
    ///
    /// `(originDeviceID, createdAt)` separates almost every pair, but not every
    /// one: two peers can hold the same content, recorded by the same device at
    /// the same instant, and still describe it differently — a representation
    /// list is a claim about what its owner can serve, so the Linux peer's is
    /// legitimately the shorter. A `>=` on that pair alone answers true in both
    /// directions there, which picks the receiver each time and makes
    /// `a.combining(b)` differ from `b.combining(a)` in every field named here.
    ///
    /// So the tie falls through, the same shape ``LWWRegister/merged(with:)``
    /// uses when a timestamp and a device both match: on to
    /// ``tieBreakKey``, which orders the remaining fields totally. The order it
    /// imposes carries no meaning and nothing reads it outside this tie-break;
    /// all it has to be is the same order on both peers.
    ///
    /// Associative as well as commutative for the case that can actually occur
    /// — ``MergeEngine/index(_:)`` folds duplicate descriptions from one peer,
    /// and one store holds one row per `contentHash`, so every element of a
    /// fold shares an `originDeviceID`. With the origin equal the choice is a
    /// plain maximum over `(createdAt, tieBreakKey)`, and a maximum is
    /// associative by construction.
    private func preferredBase(_ other: SyncClipMeta) -> SyncClipMeta {
        guard originDeviceID == other.originDeviceID else {
            return originDeviceID > other.originDeviceID ? self : other
        }
        guard createdAt == other.createdAt else { return createdAt > other.createdAt ? self : other }
        return tieBreakKey >= other.tieBreakKey ? self : other
    }

    /// The fields ``combining(_:)`` takes wholesale, rendered as one string that
    /// orders them totally.
    ///
    /// A string rather than a tuple of the fields themselves because two of them
    /// are optional and `Optional` is not `Comparable`, and a list of
    /// representations is not either. `String` comparison is defined by the
    /// standard library rather than by the host, so a Mac and a Linux box
    /// ordering the same pair reach the same answer.
    private var tieBreakKey: String {
        let representationKey = Self.joinedInjectively(
            representations.flatMap {
                ["\($0.byteCount)", $0.key.canonical, Self.rendered($0.key.origin)]
            }
        )
        return Self.joinedInjectively([
            kind,
            preview,
            isConcealed ? "1" : "0",
            Self.rendered(imageWidth.map { String($0) }),
            Self.rendered(imageHeight.map { String($0) }),
            Self.rendered(sourceBundleID),
            representationKey,
        ])
    }

    /// Concatenates components so no arrangement of characters inside one can
    /// reproduce another arrangement: each is written as its UTF-8 length, a
    /// colon, and then itself.
    ///
    /// A plain separator would not do. A preview is arbitrary user text and may
    /// contain whatever byte was chosen, and two descriptions that collided on
    /// one key would put the tie back exactly where ``preferredBase(_:)`` found
    /// it.
    private static func joinedInjectively(_ components: [String]) -> String {
        components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    /// An absent value rendered as one no present value can produce, so `nil`
    /// and `""` do not collide.
    private static func rendered(_ value: String?) -> String { value.map { "s\($0)" } ?? "n" }
}
