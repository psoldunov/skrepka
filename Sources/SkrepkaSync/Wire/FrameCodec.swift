import Foundation

/// The boundary between ``SyncMessage`` and bytes.
///
/// Framing is `[u32 big-endian length][u8 message type][CBOR body]` per design
/// §7, where `length` covers the type byte *and* the body.
///
/// Streaming-shaped from the start. ``decode(from:)`` takes the buffer `inout`
/// and consumes exactly the bytes it used, so a caller can append whatever
/// arrived and call it again. A codec that assumes whole frames arrive whole is
/// a codec that works on loopback and fails on a real TCP connection, and Phase
/// 2 wraps this in a NIO `ByteToMessageDecoder` where partial frames are the
/// normal case rather than the exception.
public enum FrameCodec {
    /// Bytes of length prefix ahead of every frame.
    static let lengthPrefixBytes = 4

    public static func encode(_ message: SyncMessage) throws -> Data {
        let body: Data
        do {
            body = try CBOREncoder.encode(SyncMessageEncoding.value(for: message))
        } catch let error as CBORError {
            throw FrameError.malformedBody(reason: error.description)
        }
        guard body.count <= SyncLimits.maximumFrameBodyBytes else {
            throw FrameError.bodyTooLarge(declaredBytes: body.count)
        }

        var frame = Data()
        frame.reserveCapacity(lengthPrefixBytes + 1 + body.count)
        let length = UInt32(body.count + 1)
        withUnsafeBytes(of: length.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(message.type.rawValue)
        frame.append(body)
        return frame
    }

    /// Decodes what it can from `buffer`, consuming the bytes it used.
    /// Returns nil when the buffer holds less than one whole frame.
    ///
    /// Three refusals, and which of them the caller may recover from is the
    /// distinction ``FrameError`` exists to draw:
    ///
    /// - ``FrameError/bodyTooLarge(declaredBytes:)`` is thrown from the length
    ///   prefix alone, before the body is waited for and long before it is
    ///   allocated. Nothing is consumed, because the rest of the frame has not
    ///   arrived and there is no boundary left to resynchronise on: the
    ///   connection is finished.
    /// - ``FrameError/unknownMessageType(rawValue:)`` consumes the whole frame
    ///   *first*. A peer speaking a newer protocol version sends types this
    ///   build has never heard of; the caller logs it and reads the next frame.
    /// - ``FrameError/truncated`` means a length that cannot even hold the type
    ///   byte, which is a stream that is not on a frame boundary.
    public static func decode(from buffer: inout Data) throws -> Frame? {
        guard buffer.count >= lengthPrefixBytes else { return nil }
        let start = buffer.startIndex

        var length: UInt32 = 0
        for offset in 0..<lengthPrefixBytes {
            length = (length << 8) | UInt32(buffer[start + offset])
        }
        guard length >= 1 else { throw FrameError.truncated }

        // Bounded while the length is still a UInt32, so nothing widens a
        // wire-supplied number into an index before it has been refused.
        // `&+` rather than `+`: the clamp already pins the left side at
        // `UInt32.max` if the limit is ever raised that far, and adding one to a
        // pinned maximum would trap — turning a raised ceiling into a crash in
        // the one function whose job is refusing oversized input.
        let maximumLength = UInt32(clamping: SyncLimits.maximumFrameBodyBytes) &+ 1
        guard length <= maximumLength else {
            throw FrameError.bodyTooLarge(declaredBytes: Int(clamping: length) - 1)
        }

        let frameBytes = lengthPrefixBytes + Int(length)
        guard buffer.count >= frameBytes else { return nil }

        let typeByte = buffer[start + lengthPrefixBytes]
        let body = Data(buffer[(start + lengthPrefixBytes + 1)..<(start + frameBytes)])
        buffer.removeSubrange(start..<(start + frameBytes))

        guard let type = SyncMessageType(rawValue: typeByte) else {
            throw FrameError.unknownMessageType(rawValue: typeByte)
        }
        return Frame(type: type, body: body)
    }

    /// Turns a frame's body into the message it framed.
    ///
    /// Separate from ``decode(from:)`` so a caller that wants to log or count
    /// frames it cannot interpret still gets to see them go past.
    public static func message(from frame: Frame) throws -> SyncMessage {
        do {
            return try SyncMessageDecoding.message(
                ofType: frame.type,
                from: try CBORDecoder.decode(frame.body)
            )
        } catch let error as CBORError {
            throw FrameError.malformedBody(reason: error.description)
        }
    }

    /// The two steps together, for a caller with no interest in frames it
    /// cannot read.
    public static func decodeMessage(from buffer: inout Data) throws -> SyncMessage? {
        guard let frame = try decode(from: &buffer) else { return nil }
        return try message(from: frame)
    }
}
