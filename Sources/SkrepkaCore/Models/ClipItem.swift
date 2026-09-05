import CryptoKit
import Foundation

/// One entry in the clipboard history, as the rest of the app sees it.
///
/// A value type on purpose: it crosses from the poller actor to the main actor
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
        self.contentHash = contentHash ?? Self.hash(kind: kind, text: text, payload: payload)
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
    static func hash(kind: ClipKind, text: String, payload: ClipPayload) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.hashDomain.utf8))
        if let identityTypes = kind.identityTypes {
            hash(payload, preferring: identityTypes, into: &hasher)
        } else {
            hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
