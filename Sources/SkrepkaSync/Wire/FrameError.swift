import Foundation

/// Why a frame was refused, spelled out far enough for a caller to decide
/// whether to drop the frame or the connection.
///
/// The distinction is the whole reason this is not one case. A peer speaking a
/// newer protocol version sends message types this build has never heard of;
/// dropping that *frame* is correct and dropping the *connection* is not.
public enum FrameError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The length prefix declares more than ``SyncLimits/maximumFrameBodyBytes``.
    ///
    /// Fatal to the connection. The bytes cannot be skipped — they have not
    /// arrived, and waiting for them is the allocation this refuses to make —
    /// so there is no way to resynchronise on the next frame boundary.
    case bodyTooLarge(declaredBytes: Int)

    /// A well-formed frame whose type byte this build does not know.
    ///
    /// Not fatal. ``FrameCodec/decode(from:)`` consumes the frame before
    /// throwing this, so the caller can log it and read the next one.
    case unknownMessageType(rawValue: UInt8)

    /// A frame whose declared length cannot hold even the type byte.
    ///
    /// Fatal: the stream is not on a frame boundary and there is nothing to
    /// resynchronise against.
    case truncated

    /// The frame was well-formed but its body was not a message of that type.
    ///
    /// Not fatal, for the same reason as ``unknownMessageType(rawValue:)``: the
    /// frame has been consumed by the time this is thrown.
    ///
    /// Carries a reason rather than the underlying CBOR error because the CBOR
    /// layer is an implementation detail of `Wire/` — the fallback the design
    /// reserved in case the codec had to be replaced only stays cheap while
    /// nothing above it names CBOR.
    case malformedBody(reason: String)

    public var description: String {
        switch self {
        case .bodyTooLarge(let declaredBytes):
            "frame declares \(declaredBytes) bytes, over the \(SyncLimits.maximumFrameBodyBytes) limit"
        case .unknownMessageType(let rawValue):
            "unknown message type \(rawValue)"
        case .truncated:
            "frame is too short to hold a message type"
        case .malformedBody(let reason):
            "malformed body: \(reason)"
        }
    }
}
