import Foundation
import Testing

@testable import SkrepkaSync

/// The file-size limit where a peer is authenticated rather than trusted: a
/// bundle riding a live push, a size understated in an offer, and a bundle
/// withheld part-way through its own fetch.
@Suite("The file-size limit against a careless or hostile peer")
struct FileSyncLimitHardeningTests {
    private static let fileHash = String(repeating: "9", count: 64)

    @Test("A negative size admits nothing, and a bundle fetch is capped by the limit as well as the budget")
    func unitRules() throws {
        #expect(!FileSyncLimit.admits(-1, under: FileSyncLimit.ceiling))
        #expect(FileSyncLimit.fetchCap(for: FileBundle.key, budget: 5_000, limit: 1_000) == 1_000)
        #expect(
            FileSyncLimit.fetchCap(for: FileSyncFixtures.fileURLKey, budget: 5_000, limit: 1_000) == 5_000)
        let bundle = try FileSyncFixtures.bundle(byteCount: 2_048)
        let payloads = [FileBundle.key: bundle, FileSyncFixtures.fileURLKey: Data("x".utf8)]
        #expect(FileSyncLimit.admitted(payloads, under: 1_024).keys.sorted() == [FileSyncFixtures.fileURLKey])
        #expect(FileSyncLimit.admitted(payloads, under: bundle.count) == payloads)
    }

    @Test("A bundle small enough to ride a live push is still dropped over the receiver's limit")
    func livePushHonoursTheReceiverLimit() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let received = ReceivedPushes()
        let responder = harness.responder(
            for: pair.serverSide,
            onLivePush: received.record,
            capabilities: SyncCapability.local,
            fileSync: FileSyncPolicy(maximumBytes: 0)
        )
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: SyncCapability.local)
        _ = try await initiator.handshake()

        let item = FileSyncFixtures.fileItem(
            Self.fileHash,
            bundle: try FileSyncFixtures.bundle(),
            deviceID: harness.clientIdentity.deviceID,
            at: harness.now
        )
        try await initiator.push(item.meta, payloads: item.payloads)

        let arrival = try await harness.eventually { await received.first() }
        #expect(arrival.inline[FileBundle.key] == nil)
        #expect(arrival.inline[FileSyncFixtures.fileURLKey] != nil)
        // Still named, so the row can say it is over the limit.
        #expect(arrival.meta.representations.contains { $0.key == FileBundle.key })
        #expect(await harness.serverStore.payload(for: Self.fileHash, key: FileBundle.key) == nil)

        await pair.close()
        _ = try? await served
    }

    @Test("A bundle whose size a peer understated is refused, not stored past the limit")
    func understatedSizeIsRefused() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let bundle = try FileSyncFixtures.bundle(byteCount: 4_096)
        let honest = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: harness.serverIdentity.deviceID, at: harness.now)
        let lying = Self.meta(honest.meta, claimingBundleBytes: 10)
        await harness.serverStore.capture(lying, payloads: honest.payloads)

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide, capabilities: SyncCapability.local)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: SyncCapability.local)
        _ = try await initiator.handshake()

        let clientStore = FakeHistoryStore()
        let runtime = FileSyncExchangeTests.runtime(
            harness: harness, store: clientStore, fileSync: FileSyncPolicy(maximumBytes: 1_024))
        await #expect(throws: SyncProtocolError.self) {
            _ = try await SyncExchange(runtime: runtime, initiator: initiator).run()
        }
        #expect(await clientStore.payload(for: Self.fileHash, key: FileBundle.key) == nil)

        await pair.close()
        _ = try? await served
    }

    @Test("A bundle withheld part-way through its fetch comes back as nothing, not as a fragment")
    func withheldMidFetchIsNotAFragment() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let bundle = try FileSyncFixtures.bundle(byteCount: SyncLimits.payloadChunkBytes * 2)
        let item = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: harness.serverIdentity.deviceID, at: harness.now)
        await harness.serverStore.capture(item.meta, payloads: item.payloads)
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let serverLimit = FileSyncPolicy()
        let responder = harness.responder(
            for: pair.serverSide, capabilities: SyncCapability.local, fileSync: serverLimit)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: SyncCapability.local)
        _ = try await initiator.handshake()
        _ = try await initiator.requestIndex(since: nil)

        // The sender lowers its limit once the first chunk is in.
        let bytes = try await initiator.fetchPayload(contentHash: Self.fileHash, key: FileBundle.key) { _ in
            await serverLimit.setMaximumBytes(0)
        }
        #expect(bytes.isEmpty)

        await pair.close()
        _ = try? await served
    }

    /// `meta` with its bundle descriptor's size replaced.
    private static func meta(_ meta: SyncClipMeta, claimingBundleBytes bytes: Int) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: meta.contentHash,
            kind: meta.kind,
            preview: meta.preview,
            createdAt: meta.createdAt,
            isPinned: meta.isPinned,
            originDeviceID: meta.originDeviceID,
            representations: meta.representations.map {
                $0.key == FileBundle.key ? RepresentationDescriptor(key: $0.key, byteCount: bytes) : $0
            }
        )
    }
}
