import Foundation

/// One resumable slice of a representation, as carried in a `payloadChunk`.
///
/// A type rather than five associated values on the message case, so the slice
/// can be passed on whole. ``offset`` and ``bytes`` only mean anything together
/// — a receiver checks that the offset continues where the last slice stopped
/// before appending — and keeping them in one value is what stops the two being
/// separated at a call site.
public struct PayloadChunk: Sendable, Hashable {
    /// The content these bytes belong to, not the row that holds it.
    public let contentHash: String
    public let key: RepresentationKey
    /// Where ``bytes`` starts within the representation.
    public let offset: Int64
    public let bytes: Data
    /// False while further slices follow, so a receiver never has to know the
    /// total length in advance.
    public let isFinal: Bool

    public init(
        contentHash: String,
        key: RepresentationKey,
        offset: Int64,
        bytes: Data,
        isFinal: Bool
    ) {
        self.contentHash = contentHash
        self.key = key
        self.offset = offset
        self.bytes = bytes
        self.isFinal = isFinal
    }
}
