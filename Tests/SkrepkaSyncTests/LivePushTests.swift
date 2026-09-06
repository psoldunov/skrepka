import Foundation
import Testing

@testable import SkrepkaSync

/// Live push over a real TLS tunnel, initiator to responder.
///
/// The direction is the point. A device only pushes over the connection it
/// dialled, which is what lets the exchange stay turn-taking without a
/// correlation identifier on the wire — so these tests are written the way the
/// app uses it, with the client pushing and the server's responder receiving.
@Suite("Live push over the wire")
struct LivePushTests {
    private static let key = RepresentationKey(canonical: "text/plain;charset=utf-8")

    @Test("A pushed item is stored and reported, with its bytes inline")
    func aPushIsStoredAndReported() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        let received = ReceivedPushes()
        let responder = harness.responder(for: pair.serverSide, onLivePush: received.record)
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID)

        let bytes = Data("pushed from the client".utf8)
        let meta = Self.meta(bytes: bytes, deviceID: harness.clientIdentity.deviceID, at: harness.now)
        async let served: Void = try responder.serve()
        try await initiator.push(meta, payloads: [Self.key: bytes])

        let arrival = try await harness.eventually { await received.first() }
        #expect(arrival.meta.contentHash == meta.contentHash)
        #expect(arrival.inline[Self.key] == bytes)

        // Stored before the sink ran, and stored with the bytes, so the item is
        // usable without a fetch.
        let index = await harness.serverStore.syncIndex(since: nil)
        #expect(index.contains { $0.contentHash == meta.contentHash })
        #expect(await harness.serverStore.payload(for: meta.contentHash, key: Self.key) == bytes)

        await pair.close()
        _ = try? await served
    }

    /// Design §11's size discipline. Above the inline limit the frame carries
    /// metadata alone, so a 20 MB screenshot never blocks the live channel — the
    /// peer fetches it from the descriptor list instead.
    @Test("A payload over the inline limit crosses as metadata alone")
    func aLargePayloadIsNotInlined() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        let received = ReceivedPushes()
        let responder = harness.responder(for: pair.serverSide, onLivePush: received.record)
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID)

        let bytes = Data(repeating: 0x41, count: SyncLimits.livePushInlineLimit + 1)
        let meta = Self.meta(bytes: bytes, deviceID: harness.clientIdentity.deviceID, at: harness.now)
        async let served: Void = try responder.serve()
        try await initiator.push(meta, payloads: [Self.key: bytes])

        let arrival = try await harness.eventually { await received.first() }
        #expect(arrival.inline.isEmpty)
        // The metadata still landed, and it still says what there is to fetch.
        #expect(arrival.meta.representations.map(\.key) == [Self.key])
        #expect(await harness.serverStore.payload(for: meta.contentHash, key: Self.key) == nil)

        await pair.close()
        _ = try? await served
    }

    /// A live push carries the same sender-stamped timestamps an index offer
    /// does, so it has to go through the same clock check. Without it a peer an
    /// hour fast would win every ordering by pushing rather than by offering.
    @Test("A push stamped past the skew window is dropped, not merged")
    func anImplausibleTimestampIsRefused() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        let received = ReceivedPushes()
        let responder = harness.responder(for: pair.serverSide, onLivePush: received.record)
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID)

        let bytes = Data("from a machine an hour fast".utf8)
        let meta = Self.meta(
            bytes: bytes,
            deviceID: harness.clientIdentity.deviceID,
            at: harness.now.addingTimeInterval(SyncLimits.maximumClockSkew + 60)
        )
        async let served: Void = try responder.serve()
        try await initiator.push(meta, payloads: [Self.key: bytes])
        // Followed by something the responder does answer, so the assertion is
        // about a message that was processed and dropped rather than about one
        // that had not arrived yet.
        try await pair.client.send(.ping(nonce: 1))
        #expect(try await pair.client.receive() == .ping(nonce: 1))

        #expect(await received.isEmpty())
        #expect(
            await harness.serverStore.syncIndex(since: nil).allSatisfy {
                $0.contentHash != meta.contentHash
            }
        )

        await pair.close()
        _ = try? await served
    }

    private static func meta(bytes: Data, deviceID: SyncDeviceID, at now: Date) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: String(repeating: "b", count: 64),
            kind: "text",
            preview: "pushed",
            createdAt: now,
            isPinned: LWWRegister(value: false, timestamp: now, deviceID: deviceID),
            originDeviceID: deviceID,
            representations: [RepresentationDescriptor(key: key, byteCount: bytes.count)]
        )
    }
}

/// What a responder's live-push sink saw.
///
/// An actor because the sink is `@Sendable` and runs on whatever task the
/// responder is on, while the test reads it from another.
actor ReceivedPushes {
    struct Arrival: Sendable {
        let meta: SyncClipMeta
        let inline: [RepresentationKey: Data]
    }

    private var arrivals: [Arrival] = []

    /// The sink itself, so a test can hand `received.record` straight to a
    /// responder.
    nonisolated var record: LivePushSink {
        { [self] meta, inline in
            await append(Arrival(meta: meta, inline: inline))
        }
    }

    private func append(_ arrival: Arrival) { arrivals.append(arrival) }

    func first() -> Arrival? { arrivals.first }
    func isEmpty() -> Bool { arrivals.isEmpty }
}
