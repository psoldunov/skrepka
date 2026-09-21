import Foundation
import Testing

@testable import SkrepkaSync

/// A push too large to carry its bytes is fetched straight away, rather than
/// on the exchange up to thirty seconds later.
@Suite("Fetch on push")
struct FetchOnPushTests {
    private static let key = RepresentationKey(canonical: "image/png", origin: "public.png")

    @Test("A push without its bytes asks for a fetch from its sender; one with them does not")
    func responderAsksForAFetch() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let requests = PushRequests()
        let responder = harness.responder(for: pair.serverSide, onPushWithoutBytes: requests.record)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(for: pair.client, expecting: harness.serverIdentity.deviceID)

        let small = Self.item("a", byteCount: 16, harness: harness)
        let large = Self.item("b", byteCount: SyncLimits.livePushInlineLimit + 1, harness: harness)
        try await initiator.push(small.meta, payloads: small.payloads)
        try await initiator.push(large.meta, payloads: large.payloads)
        try await pair.client.send(.ping(nonce: 1))
        #expect(try await pair.client.receive() == .ping(nonce: 1))

        let asked = await requests.all()
        #expect(asked.map(\.meta.contentHash) == [large.meta.contentHash])
        #expect(asked.first?.sender == harness.clientIdentity.deviceID)

        await pair.close()
        _ = try? await served
    }

    @Test("An exchange fetches the pushed item first, however old it is")
    func priorityGoesFirst() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        // Older than the harness's own item, so newest-first would reach it last.
        let pushed = Self.item("c", byteCount: 32, harness: harness, age: 60)
        await harness.serverStore.capture(pushed.meta, payloads: pushed.payloads)

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(for: pair.client, expecting: harness.serverIdentity.deviceID)
        _ = try await initiator.handshake()

        let fetched = FetchedItems()
        let runtime = FileCapabilityTests.runtime(harness: harness, store: FakeHistoryStore())
        let exchange = SyncExchange(
            runtime: runtime,
            initiator: initiator,
            priority: pushed.meta.contentHash,
            onFetched: fetched.record
        )
        _ = try await exchange.run()

        #expect(await fetched.hashes() == [pushed.meta.contentHash, LoopbackHarness.contentHash])
        await pair.close()
        _ = try? await served
    }

    @Test("A representation that does not fit what is left of the budget waits for the next round")
    func budgetDefersWhatDoesNotFit() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let (meta, png, jpeg) = Self.twoPictures(harness: harness)
        await harness.serverStore.capture(meta, payloads: [Self.key: png, Self.jpegKey: jpeg])

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(for: pair.client, expecting: harness.serverIdentity.deviceID)
        _ = try await initiator.handshake()

        let store = FakeHistoryStore()
        let runtime = FileCapabilityTests.runtime(harness: harness, store: store)
        let round = { (fetched: FetchedItems) in
            SyncExchange(
                runtime: runtime,
                initiator: initiator,
                priority: nil,
                budget: 1000,
                onFetched: fetched.record
            )
        }
        let fetched = FetchedItems()
        _ = try await round(fetched).run()
        // 600 + 600 is over 1000: one of the two, not both — and the round
        // goes on to what does fit rather than stopping there.
        #expect(await fetched.items.first { $0.meta.contentHash == meta.contentHash }?.payloads.count == 1)
        #expect(await fetched.hashes().contains(LoopbackHarness.contentHash))
        let held = [
            await store.payload(for: meta.contentHash, key: Self.key),
            await store.payload(for: meta.contentHash, key: Self.jpegKey),
        ]
        #expect(held.compactMap(\.self).count == 1)

        await pair.close()
        _ = try? await served
    }

    @Test("A link handed a push fetches it now and hands the bytes on")
    func linkFetchesAPushNow() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let server = try await harness.startServer(
            identity: harness.serverIdentity, policy: .pinned([harness.clientIdentity.deviceID]))
        let serving = Task {
            while let connection = await server.nextConnection() {
                // A responder ends by throwing when its peer hangs up, which
                // is how every connection in this test ends.
                Task { try? await harness.responder(for: connection).serve() }
            }
        }

        let events = LinkEvents()
        let delivered = FetchedItems()
        let link = PeerLink(
            peerDeviceID: harness.serverIdentity.deviceID,
            runtime: FileCapabilityTests.runtime(harness: harness, store: FakeHistoryStore()),
            resolve: { try Self.resolved(harness: harness, port: server.port) },
            report: { _, event in await events.record(event) },
            onPushFetched: delivered.record
        )
        await link.start()
        _ = try await harness.eventually { await events.hasSynced() ? true : nil }

        // The peer copies something large and pushes it; its bytes are not
        // in the push, and the next scheduled exchange is thirty seconds away.
        let pushed = Self.item("d", byteCount: SyncLimits.livePushInlineLimit + 1, harness: harness)
        await harness.serverStore.capture(pushed.meta, payloads: pushed.payloads)
        await link.fetchPushed(pushed.meta)

        let arrival = try await harness.eventually(within: 10) { await delivered.items.first }
        #expect(arrival.meta.contentHash == pushed.meta.contentHash)
        #expect(arrival.payloads[Self.key] == pushed.payloads[Self.key])
        // Only the pushed item is handed on, not everything the exchange fetched.
        #expect(await delivered.hashes() == [pushed.meta.contentHash])

        await link.stop()
        serving.cancel()
        await server.stop()
    }

    // MARK: - Fixtures

    private static let jpegKey = RepresentationKey(canonical: "image/jpeg", origin: "public.jpeg")

    /// One item offered as two 600-byte pictures.
    private static func twoPictures(harness: LoopbackHarness) -> (meta: SyncClipMeta, png: Data, jpeg: Data) {
        let png = Data(repeating: 1, count: 600)
        let jpeg = Data(repeating: 2, count: 600)
        let date = harness.now.addingTimeInterval(60)
        let meta = SyncClipMeta(
            contentHash: String(repeating: "9", count: 64),
            kind: "image",
            preview: "Image",
            createdAt: date,
            isPinned: LWWRegister(value: false, timestamp: date, deviceID: harness.serverIdentity.deviceID),
            originDeviceID: harness.serverIdentity.deviceID,
            representations: [
                RepresentationDescriptor(key: key, byteCount: png.count),
                RepresentationDescriptor(key: jpegKey, byteCount: jpeg.count),
            ]
        )
        return (meta, png, jpeg)
    }

    private static func item(
        _ letter: Character,
        byteCount: Int,
        harness: LoopbackHarness,
        age: TimeInterval = 0
    ) -> (meta: SyncClipMeta, payloads: [RepresentationKey: Data]) {
        let bytes = Data(repeating: 0x42, count: byteCount)
        let date = harness.now.addingTimeInterval(-age)
        let meta = SyncClipMeta(
            contentHash: String(repeating: letter, count: 64),
            kind: "image",
            preview: "Image",
            createdAt: date,
            isPinned: LWWRegister(value: false, timestamp: date, deviceID: harness.clientIdentity.deviceID),
            originDeviceID: harness.clientIdentity.deviceID,
            representations: [RepresentationDescriptor(key: key, byteCount: bytes.count)]
        )
        return (meta, [key: bytes])
    }

    private static func resolved(harness: LoopbackHarness, port: Int) throws -> ResolvedPeer {
        let advertisement = PeerAdvertisement(
            deviceID: harness.serverIdentity.deviceID,
            displayName: "server",
            platform: .macos,
            protocolVersion: .current
        )
        return ResolvedPeer(
            peer: DiscoveredPeer(
                instanceName: "server",
                serviceType: "_skrepka._tcp",
                domain: "local.",
                interfaceIndex: nil,
                advertisement: .unread
            ),
            host: LoopbackHarness.host,
            port: UInt16(port),
            advertisement: advertisement
        )
    }
}

/// What a responder asked to have fetched.
actor PushRequests {
    private var requests: [(sender: SyncDeviceID, meta: SyncClipMeta)] = []

    nonisolated func record(_ sender: SyncDeviceID, _ meta: SyncClipMeta) async {
        await append(sender, meta)
    }

    private func append(_ sender: SyncDeviceID, _ meta: SyncClipMeta) {
        requests.append((sender, meta))
    }

    func all() -> [(sender: SyncDeviceID, meta: SyncClipMeta)] { requests }
}

/// What a link reported about itself.
actor LinkEvents {
    private var events: [PeerLinkEvent] = []

    nonisolated func record(_ event: PeerLinkEvent) async {
        await append(event)
    }

    private func append(_ event: PeerLinkEvent) { events.append(event) }

    func hasSynced() -> Bool {
        events.contains {
            if case .synced = $0 { return true }
            return false
        }
    }
}
