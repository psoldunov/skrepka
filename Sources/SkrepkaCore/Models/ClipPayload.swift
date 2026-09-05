import Foundation

/// Every pasteboard representation worth restoring, keyed by pasteboard type.
///
/// Keeping all of them is what makes paste-back lossless: copying styled text
/// out of Pages and pasting it back should still be styled.
public struct ClipPayload: Sendable, Hashable {
    /// Pasteboard type raw value to its data.
    public let representations: [String: Data]

    public init(representations: [String: Data]) {
        self.representations = representations
    }

    public func data(forType type: String) -> Data? {
        representations[type]
    }

    public var isEmpty: Bool {
        representations.isEmpty
    }

    /// Total bytes across every representation, used for size limits.
    public var byteCount: Int {
        representations.values.reduce(0) { $0 + $1.count }
    }

    /// The file the entry points at, when it carries a `public.file-url`.
    ///
    /// That representation is the absolute URL string and nothing else, so
    /// every caller that wants the file — the kind rules, the preview — has to
    /// decode it the same way. Once is enough.
    ///
    /// `nil` for a payload with no file URL, and for one whose bytes are not a
    /// file URL at all: an app is free to put anything under that type, and
    /// this returning a `https:` URL would send the rest of the code looking
    /// for it on disk.
    public var fileURL: URL? {
        guard let data = data(forType: PasteboardType.fileURL),
            let string = String(data: data, encoding: .utf8),
            let url = URL(string: string), url.isFileURL
        else { return nil }
        return url
    }

    /// Every representation in a stable order. Dictionary iteration order is
    /// not, so hashing has to sort first or the same payload hashes two ways.
    var sortedRepresentations: [(type: String, data: Data)] {
        representations.sorted { $0.key < $1.key }.map { (type: $0.key, data: $0.value) }
    }

    /// Drops every representation except plain text, for "paste as plain text".
    public func plainTextOnly(_ text: String) -> ClipPayload {
        ClipPayload(representations: [PasteboardType.string: Data(text.utf8)])
    }
}
