import Foundation
import Testing

@testable import SkrepkaSync

/// The framing boundary: `[u32 big-endian length][u8 message type][CBOR body]`,
/// where `length` covers the type byte and the body.
@Suite("Frame codec")
struct FrameCodecTests {
    /// Builds a frame header by hand, so a test can declare a length the
    /// encoder would never produce.
    private func header(length: UInt32, type: UInt8) -> Data {
        var data = Data()
        withUnsafeBytes(of: length.bigEndian) { data.append(contentsOf: $0) }
        data.append(type)
        return data
    }

    @Test("Every message type encodes and decodes to an equal value")
    func roundTripsEveryMessageType() throws {
        let messages = SyncFixtures.allMessages()
        #expect(Set(messages.keys) == Set(SyncMessageType.allCases))

        for type in SyncMessageType.allCases {
            let original = try #require(messages[type])
            var buffer = try FrameCodec.encode(original)
            let decoded = try #require(try FrameCodec.decodeMessage(from: &buffer))
            #expect(decoded == original)
            #expect(decoded.type == type)
            #expect(buffer.isEmpty)
        }
    }

    /// The one field with a value the fixture table cannot carry twice.
    @Test("An index request with no cursor round-trips as nil")
    func roundTripsAbsentCursor() throws {
        var buffer = try FrameCodec.encode(.indexRequest(since: nil))
        #expect(try FrameCodec.decodeMessage(from: &buffer) == .indexRequest(since: nil))
    }

    /// The declared length is refused from the header alone, before the body is
    /// waited for and long before it is allocated: a five-byte header is all it
    /// takes to ask for 33 MB.
    @Test("A body one byte over the limit is refused without being allocated")
    func rejectsOversizedBody() {
        let overLimit = UInt32(SyncLimits.maximumFrameBodyBytes + 1)
        var buffer = header(length: overLimit + 1, type: SyncMessageType.ping.rawValue)
        let sent = buffer.count

        #expect(throws: FrameError.bodyTooLarge(declaredBytes: Int(overLimit))) {
            try FrameCodec.decode(from: &buffer)
        }
        // Nothing consumed: the frame never arrived, so there is no boundary to
        // resynchronise on and the caller's only correct move is to hang up.
        #expect(buffer.count == sent)

        // The largest legal body is still accepted from the header alone — the
        // limit is a ceiling, not an off-by-one away from one.
        var atTheLimit = header(
            length: UInt32(SyncLimits.maximumFrameBodyBytes) + 1,
            type: SyncMessageType.ping.rawValue
        )
        #expect(throws: Never.self) { try FrameCodec.decode(from: &atTheLimit) }
    }

    @Test("A buffer holding half a frame yields nil and consumes nothing")
    func returnsNilOnPartialFrame() throws {
        let whole = try FrameCodec.encode(.ping(nonce: 7))
        #expect(whole.count > 6)

        for prefix in [0, 1, 3, 4, 5, whole.count - 1] {
            var buffer = whole.prefix(prefix)
            #expect(try FrameCodec.decode(from: &buffer) == nil)
            #expect(buffer.count == prefix)
        }

        // And the moment the last byte arrives, the same buffer decodes.
        var buffer = whole.prefix(whole.count - 1)
        #expect(try FrameCodec.decode(from: &buffer) == nil)
        buffer.append(try #require(whole.last))
        #expect(try FrameCodec.decodeMessage(from: &buffer) == .ping(nonce: 7))
    }

    /// The streaming case loopback would otherwise hide: two frames in one
    /// read, then a third arriving a byte at a time.
    @Test("Two frames in one buffer decode one after the other")
    func decodesTwoFramesFromOneBuffer() throws {
        let first = SyncMessage.ping(nonce: 1)
        let second = SyncMessage.indexRequest(since: SyncFixtures.time(3))
        let third = SyncMessage.itemMeta(SyncFixtures.meta("aa"))

        let encodedFirst = try FrameCodec.encode(first)
        let encodedSecond = try FrameCodec.encode(second)
        var buffer = encodedFirst + encodedSecond
        #expect(try FrameCodec.decodeMessage(from: &buffer) == first)
        #expect(try FrameCodec.decodeMessage(from: &buffer) == second)
        #expect(buffer.isEmpty)
        #expect(try FrameCodec.decodeMessage(from: &buffer) == nil)

        // And the same again, one byte at a time: nothing decodes until the
        // last byte lands.
        for byte in try FrameCodec.encode(third) {
            #expect(try FrameCodec.decode(from: &buffer) == nil)
            buffer.append(byte)
        }
        #expect(try FrameCodec.decodeMessage(from: &buffer) == third)
    }

    /// A peer speaking a newer protocol version sends types this build has
    /// never heard of. Dropping that *frame* is correct; dropping the
    /// *connection* is not — so the frame is consumed before the error is
    /// thrown, and the next frame still decodes.
    @Test("An unknown message type is refused without derailing the stream")
    func rejectsUnknownMessageType() throws {
        let unknown = UInt8(200)
        #expect(SyncMessageType(rawValue: unknown) == nil)

        let body = try CBOREncoder.encode(.map(fields: ["future": .boolean(true)]))
        var buffer = header(length: UInt32(body.count + 1), type: unknown) + body
        buffer.append(try FrameCodec.encode(.ping(nonce: 9)))

        #expect(throws: FrameError.unknownMessageType(rawValue: unknown)) {
            try FrameCodec.decode(from: &buffer)
        }
        #expect(try FrameCodec.decodeMessage(from: &buffer) == .ping(nonce: 9))
    }

    /// A length prefix that cannot hold even the type byte. Unlike an unknown
    /// type this is unrecoverable — the stream is not on a frame boundary.
    @Test("A zero-length frame is refused as truncated")
    func rejectsZeroLengthFrame() {
        var buffer = Data([0, 0, 0, 0, 0, 0])
        #expect(throws: FrameError.truncated) { try FrameCodec.decode(from: &buffer) }
    }

    /// OQ-8 turned into a regression test: a malformed body throws rather than
    /// trapping, and — because the frame has been consumed by then — the
    /// connection survives it.
    @Test("Malformed and truncated bodies throw rather than trap")
    func survivesMalformedBody() throws {
        let legal = try FrameCodec.encode(.itemMeta(SyncFixtures.meta("aa")))
        let bodyStart = FrameCodec.lengthPrefixBytes + 1

        var bodies: [Data] = [
            Data(),  // no body at all
            Data(legal.dropFirst(bodyStart).dropLast(3)),  // truncated CBOR
            Data([0x9b, 0, 0, 1, 0, 0, 0, 0, 0]),  // an array of 2^40 elements
            Data(repeating: 0x81, count: 4096),  // a nesting bomb
            Data([0xf6]),  // well-formed CBOR of the wrong shape
            Data([0xa1, 0x61, 0x61, 0x01]),  // a map missing every field
        ]
        // Every single-byte corruption of a legal body, which is the case a
        // hand-written decoder is likeliest to have a hole in.
        for offset in stride(from: bodyStart, to: legal.count, by: 7) {
            var corrupted = legal
            corrupted[corrupted.startIndex + offset] ^= 0xff
            bodies.append(Data(corrupted.dropFirst(bodyStart)))
        }

        for body in bodies {
            var buffer = header(length: UInt32(body.count + 1), type: SyncMessageType.itemMeta.rawValue)
            buffer.append(body)
            // Either it throws, or it decodes to something — never a trap, and
            // never a partially consumed buffer.
            let decoded = try? FrameCodec.decodeMessage(from: &buffer)
            #expect(decoded == nil || decoded?.type == .itemMeta)
            #expect(buffer.isEmpty)
        }
    }

    /// The length prefix is big-endian, which is worth pinning: a
    /// little-endian writer would interoperate with itself and with nothing
    /// else.
    @Test("The length prefix is big-endian and covers the type byte")
    func framesWithABigEndianLengthPrefix() throws {
        let frame = try FrameCodec.encode(.ping(nonce: 0))
        let declared = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        #expect(Int(declared) == frame.count - FrameCodec.lengthPrefixBytes)
        #expect(frame[frame.startIndex + 4] == SyncMessageType.ping.rawValue)
    }

    /// Encoding is deterministic all the way out to the frame, which is what
    /// Phase 2's short authentication string will be hashed over.
    @Test("The same message encodes to the same bytes every time")
    func encodesDeterministically() throws {
        for message in SyncFixtures.allMessages().values {
            let first = try FrameCodec.encode(message)
            let second = try FrameCodec.encode(message)
            #expect(first == second)
        }
    }
}
