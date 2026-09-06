import Foundation

// swift-crypto is source-identical to CryptoKit — on Apple platforms it
// compiles its API surface away and re-exports CryptoKit, so `SHA256` here is
// the same algorithm producing the same bytes either way. `ClipItemTests`
// pins that with a known-answer vector rather than trusting the claim, because
// `contentHash` is the sync model's identity and a divergence would be silent.
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// One entry in the clipboard history, as the rest of the app sees it.
///
/// A value type on purpose: it crosses from the watcher actor to the main actor
/// on every capture, and `Sendable` for free is worth more than in-place edits.
public struct ClipItem: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let kind: ClipKind
    /// Plain-text rendering, used for search, the row label and plain paste.
    public let text: String
    public let payload: ClipPayload
    /// Bundle identifier of whatever was frontmost when the copy happened.
    public let sourceBundleID: String?
    public let createdAt: Date
    public let isPinned: Bool
    /// Set when the item carried a password-manager "concealed" marker. Stored
    /// but never rendered in the clear.
    public let isConcealed: Bool
    /// Stable hash of the content, used to collapse repeated copies.
    public let contentHash: String
    /// Pixel dimensions, when the entry is an image.
    public let imageSize: ImageSize?
    /// Every file the copy holds, in the order the pasteboard listed them.
    ///
    /// Copying three files in Finder puts three items on the pasteboard, one
    /// file URL each, and ``ClipPayload`` only ever holds the first — see
    /// ``PasteboardSnapshot``. Without this the other two are lost: the row
    /// counts them, but pasting restores one file.
    ///
    /// Empty for everything that is not a file. A file entry built from a
    /// payload alone — which is what the store's tests do, and what a capture
    /// off a single-item pasteboard amounts to — resolves to the one file its
    /// payload names, so every reader can take this list as the whole answer
    /// instead of falling back to the payload itself.
    ///
    /// Each file appears once. A copy cannot hold the same file twice, and a
    /// list that said it did would be wrong in four places at once: it would
    /// paste that file twice, weigh it twice, count it twice on the row, and
    /// hash as a selection distinct from the one it actually is. The capture
    /// rules already drop duplicates; holding the invariant here means every
    /// other way of building an entry gets it too.
    public let fileURLs: [URL]

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        text: String,
        payload: ClipPayload,
        sourceBundleID: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        isConcealed: Bool = false,
        imageSize: ImageSize? = nil,
        fileURLs: [URL] = [],
        contentHash: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.payload = payload
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.isConcealed = isConcealed
        self.imageSize = imageSize
        let listed = fileURLs.isEmpty ? [payload.fileURL].compactMap(\.self) : fileURLs
        var seen: Set<URL> = []
        let files = listed.filter { seen.insert($0).inserted }
        self.fileURLs = files
        self.contentHash =
            contentHash ?? Self.hash(kind: kind, text: text, payload: payload, fileURLs: files)
    }

    /// Pixel dimensions of an image entry.
    public struct ImageSize: Sendable, Hashable, Codable {
        public let width: Int
        public let height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        public var description: String { "\(width) × \(height)" }
    }

    /// Single-line preview, collapsed and trimmed for display in a row.
    public var previewText: String {
        guard !isConcealed else { return PreviewText.concealedMask }
        return PreviewText.collapsed(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func withPinned(_ pinned: Bool) -> ClipItem {
        ClipItem(
            id: id,
            kind: kind,
            text: text,
            payload: payload,
            sourceBundleID: sourceBundleID,
            createdAt: createdAt,
            isPinned: pinned,
            isConcealed: isConcealed,
            imageSize: imageSize,
            fileURLs: fileURLs,
            contentHash: contentHash
        )
    }

    /// Content identity, used to collapse a repeat copy onto its existing entry.
    ///
    /// Text-shaped kinds hash their text, so the same sentence copied out of two
    /// different apps is one entry. Images and files hash payload bytes instead
    /// — see ``ClipKind/identityTypes``. Hashing their ``text`` would be a hash
    /// of a display string, and a collision there does not merge two entries,
    /// it discards the newer one.
    ///
    /// A copy of several files is identified by the whole set instead. The
    /// payload holds the first file and no more, so identifying a selection by
    /// it makes `[report.pdf, jan.csv]` and `[report.pdf, feb.csv]` one entry —
    /// the second copy is discarded onto the first, and the files it held are
    /// gone.
    static func hash(kind: ClipKind, text: String, payload: ClipPayload, fileURLs: [URL]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.hashDomain.utf8))
        if kind.isFileSystemEntry && fileURLs.count > 1 {
            hash(selection: fileURLs, into: &hasher)
        } else if let identityTypes = kind.identityTypes {
            hash(payload, preferring: identityTypes, into: &hasher)
        } else {
            hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Feeds a whole copied selection into `hasher`, and nothing else.
    ///
    /// Sorted, because the pasteboard's order is the order the files happened to
    /// be clicked in: the same three files copied twice are the same copy, and
    /// ordering the hash by selection would file the second as a new entry.
    ///
    /// The payload deliberately takes no part. It carries whichever file came
    /// first, which is exactly what the order is not allowed to decide — and a
    /// lone file never reaches here, so its hash stays what it has always been
    /// and re-copying it still lands on its own row instead of duplicating it.
    private static func hash(selection urls: [URL], into hasher: inout SHA256) {
        for url in urls.map(\.absoluteString).sorted() {
            hasher.update(data: Data(url.utf8))
        }
    }

    /// Feeds the richest ranked representation into `hasher`, or every
    /// representation when none of them is present.
    ///
    /// The fallback costs a full pass over the payload, and is worth it: an
    /// entry that matches no ranked type would otherwise hash to nothing but
    /// its kind, and every such entry would collapse onto the first one.
    private static func hash(
        _ payload: ClipPayload,
        preferring types: [String],
        into hasher: inout SHA256
    ) {
        for type in types {
            guard let data = payload.data(forType: type) else { continue }
            hasher.update(data: Data(type.utf8))
            hasher.update(data: data)
            return
        }
        for (type, data) in payload.sortedRepresentations {
            hasher.update(data: Data(type.utf8))
            hasher.update(data: data)
        }
    }
}
