import Foundation
import NIOCore

/// NIO's streaming boundary over ``FrameCodec``.
///
/// The size cap is enforced **from the length prefix, before a single byte of
/// body is waited for or allocated**. A peer claiming a 4 GB body has sent four
/// bytes at that point, and this refuses on those four: reading `readableBytes`
/// first and the limit second would mean holding the connection open until 4 GB
/// arrived, which is the denial of service the cap exists to stop.
///
/// ``FrameCodec/decode(from:)`` re-checks the same limit. That duplication is
/// deliberate — the codec's check is what makes the codec safe in isolation,
/// and this one is what keeps the allocation from happening in NIO's buffer.
struct FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = Frame

    /// Called with the type byte of a frame this build does not recognise.
    ///
    /// Not optional and with no default, because the alternative shapes are a
    /// silently discarded frame and a connection killed by a peer running a
    /// newer protocol — and ``FrameError`` exists precisely to keep those two
    /// apart.
    let onUnknownFrame: @Sendable (UInt8) -> Void

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard
            let declared = buffer.getInteger(
                at: buffer.readerIndex,
                endianness: .big,
                as: UInt32.self
            )
        else { return .needMoreData }

        // A length that cannot hold even the type byte means the stream is not
        // on a frame boundary, and there is nothing to resynchronise against.
        guard declared >= 1 else { throw FrameError.truncated }

        // `&+` for the reason `FrameCodec.decode` gives: the clamp pins at
        // `UInt32.max`, and `+ 1` on a pinned maximum traps.
        let ceiling = UInt32(clamping: SyncLimits.maximumFrameBodyBytes) &+ 1
        guard declared <= ceiling else {
            throw FrameError.bodyTooLarge(declaredBytes: Int(clamping: declared) - 1)
        }

        let frameBytes = FrameCodec.lengthPrefixBytes + Int(declared)
        guard buffer.readableBytes >= frameBytes else { return .needMoreData }
        guard let frameBody = buffer.readBytes(length: frameBytes) else { return .needMoreData }
        var frameData = Data(frameBody)

        do {
            // Handed exactly one frame's worth of bytes, so a nil return would
            // mean the two length checks disagree. It cannot happen, and if it
            // ever did, a stream this handler no longer understands is fatal.
            guard let frame = try FrameCodec.decode(from: &frameData) else {
                throw FrameError.truncated
            }
            context.fireChannelRead(wrapInboundOut(frame))
        } catch FrameError.unknownMessageType(let rawValue) {
            // The frame was consumed above, so the stream is still on a
            // boundary and the next one is readable. A peer speaking a newer
            // protocol version is a peer worth carrying on with.
            onUnknownFrame(rawValue)
        }
        return .continue
    }

    mutating func decodeLast(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer,
        seenEOF: Bool
    ) throws -> DecodingState {
        // A whole frame can arrive in the same read as the close, so this runs
        // the same decode rather than discarding what is left.
        try decode(context: context, buffer: &buffer)
    }
}
