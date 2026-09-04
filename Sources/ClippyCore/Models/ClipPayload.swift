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
