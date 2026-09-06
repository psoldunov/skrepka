import Foundation

/// A pasteboard's contents frozen into a value.
///
/// Everything downstream of this is pure, so capture rules can be tested
/// without a live `NSPasteboard`.
public struct PasteboardSnapshot: Sendable, Hashable {
    /// Representations of the first pasteboard item, keyed by type.
    public let representations: [String: Data]
    /// Types present on the item, including ones with no data (privacy markers
    /// are frequently declared with empty payloads).
    public let declaredTypes: [String]
    /// The file URL of every item on the pasteboard, in the order they were
    /// listed — the first of them is the one inside ``representations``.
    ///
    /// A copy of several files is several pasteboard items carrying one
    /// `public.file-url` each, so this is the only place the rest of them exist.
    /// Empty for a copy that named no file at all.
    public let fileURLs: [URL]
    public let sourceBundleID: String?
    public let capturedAt: Date

    public init(
        representations: [String: Data],
        declaredTypes: [String],
        fileURLs: [URL] = [],
        sourceBundleID: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.representations = representations
        self.declaredTypes = declaredTypes
        self.fileURLs = fileURLs
        self.sourceBundleID = sourceBundleID
        self.capturedAt = capturedAt
    }
}
