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
    public let sourceBundleID: String?
    public let capturedAt: Date

    public init(
        representations: [String: Data],
        declaredTypes: [String],
        sourceBundleID: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.representations = representations
        self.declaredTypes = declaredTypes
        self.sourceBundleID = sourceBundleID
        self.capturedAt = capturedAt
    }
}
