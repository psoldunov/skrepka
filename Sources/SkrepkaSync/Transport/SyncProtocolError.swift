import Foundation

/// A peer that is speaking the protocol wrongly, as opposed to one that is
/// speaking it and being refused.
public enum SyncProtocolError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The peer went away where an answer was required.
    case connectionClosed

    case unexpectedMessage(expected: SyncMessageType, got: SyncMessageType)

    /// A `payloadChunk` that does not continue where the last one stopped.
    ///
    /// Refused rather than reordered: chunks are requested one at a time by
    /// offset, so a mismatch means the two ends disagree about what is being
    /// fetched, and stitching the bytes together anyway would produce a
    /// payload whose hash is nobody's.
    case payloadOutOfOrder(expected: Int64, got: Int64)

    /// A payload that grew past ``SyncLimits/maximumPayloadBytes`` across
    /// chunks. Each chunk is inside the frame limit; their sum need not be.
    case payloadTooLarge(bytes: Int)

    public var description: String {
        switch self {
        case .connectionClosed:
            "the peer closed the connection before answering"
        case .unexpectedMessage(let expected, let got):
            "expected \(expected) and the peer sent \(got)"
        case .payloadOutOfOrder(let expected, let got):
            "expected a chunk at offset \(expected) and the peer sent one at \(got)"
        case .payloadTooLarge(let bytes):
            "payload reached \(bytes) bytes, over the \(SyncLimits.maximumPayloadBytes) limit"
        }
    }
}
