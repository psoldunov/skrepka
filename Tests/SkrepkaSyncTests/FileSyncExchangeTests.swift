import Foundation
import Testing

@testable import SkrepkaSync

/// The file-size limit and progress reporting, end to end over a real
/// connection: what a receiver fetches under its own limit, what a sender
/// offers under its, and what a fetch reports as it goes.
@Suite("Syncing files under a size limit")
struct FileSyncExchangeTests {
    private static let fileHash = String(repeating: "e", count: 64)
    /// Three chunks' worth, so a fetch has progress to report between them.
    private static let bundleBytes = SyncLimits.payloadChunkBytes * 2 + 1_000

    @Test("A receiver does not fetch a bundle over its own limit, and does under it")
    func receiverLimit() async throws {
        for (limit, expectsBundle) in [(0, false), (1_024, false), (FileSyncLimit.ceiling, true)] {
            let fetched = try await exchange(receiverLimit: limit, senderLimit: FileSyncLimit.ceiling)
            #expect((fetched.bundle != nil) == expectsBundle, "limit \(limit)")
            // The path travels whatever the limit: the row still arrives.
            #expect(fetched.path != nil, "limit \(limit)")
        }
    }

    @Test("A sender does not offer a bundle over its own limit, even one captured under a higher one")
    func senderLimit() async throws {
        let fetched = try await exchange(receiverLimit: FileSyncLimit.ceiling, senderLimit: 1_024)
        #expect(fetched.bundle == nil)
        #expect(fetched.path != nil)
    }

    @Test("A finished fetch leaves nothing in flight")
    func transfersEnd() async throws {
        let fetched = try await exchange(
            receiverLimit: FileSyncLimit.ceiling, senderLimit: FileSyncLimit.ceiling)
        let expected = try FileSyncFixtures.bundle(byteCount: Self.bundleBytes)
        #expect(fetched.bundle == expected)
        #expect(fetched.inFlightAfter.isEmpty)
    }

    @Test("Fetching a payload reports the running count after every chunk but the last")
    func chunkProgress() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let bundle = try FileSyncFixtures.bundle(byteCount: Self.bundleBytes)
        let item = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: harness.serverIdentity.deviceID, at: harness.now)
        await harness.serverStore.capture(item.meta, payloads: item.payloads)
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide, capabilities: SyncCapability.local)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: SyncCapability.local)
        _ = try await initiator.handshake()
        _ = try await initiator.requestIndex(since: nil)

        let counts = ChunkCounts()
        let bytes = try await initiator.fetchPayload(contentHash: Self.fileHash, key: FileBundle.key) {
            await counts.record($0)
        }
        #expect(bytes == bundle)
        let chunk = SyncLimits.payloadChunkBytes
        #expect(await counts.values == [chunk, chunk * 2])

        await pair.close()
        _ = try? await served
    }

    // MARK: - Helpers

    private struct Fetched {
        let bundle: Data?
        let path: Data?
        let inFlightAfter: [PayloadTransfer]
    }

    /// One exchange from a client with `receiverLimit` against a server with
    /// `senderLimit` that holds one file item.
    private func exchange(receiverLimit: Int, senderLimit: Int) async throws -> Fetched {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let bundle = try FileSyncFixtures.bundle(byteCount: Self.bundleBytes)
        let item = FileSyncFixtures.fileItem(
            Self.fileHash, bundle: bundle, deviceID: harness.serverIdentity.deviceID, at: harness.now)
        await harness.serverStore.capture(item.meta, payloads: item.payloads)

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(
            for: pair.serverSide,
            capabilities: SyncCapability.local,
            fileSync: FileSyncPolicy(maximumBytes: senderLimit)
        )
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: SyncCapability.local)
        _ = try await initiator.handshake()

        let clientStore = FakeHistoryStore()
        let runtime = Self.runtime(
            harness: harness, store: clientStore, fileSync: FileSyncPolicy(maximumBytes: receiverLimit))
        _ = try await SyncExchange(runtime: runtime, initiator: initiator).run()

        let fetched = Fetched(
            bundle: await clientStore.payload(for: Self.fileHash, key: FileBundle.key),
            path: await clientStore.payload(for: Self.fileHash, key: FileSyncFixtures.fileURLKey),
            inFlightAfter: await runtime.transfers.current
        )
        await pair.close()
        _ = try? await served
        return fetched
    }

    static func runtime(
        harness: LoopbackHarness,
        store: any HistoryStoring,
        fileSync: FileSyncPolicy
    ) -> SyncRuntime {
        SyncRuntime(
            certificate: harness.clientIdentity,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: harness.clientIdentity.deviceID,
                    deviceName: "client",
                    platform: .linux,
                    protocolVersion: .current,
                    capabilities: SyncCapability.local
                ),
                localCertificate: harness.clientIdentity
            ),
            trust: harness.clientTrust,
            store: store,
            group: harness.group,
            fileSync: fileSync,
            transfers: TransferMonitor(progressInterval: .zero)
        )
    }
}

/// Running byte counts, as `fetchPayload` reported them.
private actor ChunkCounts {
    private(set) var values: [Int] = []

    func record(_ count: Int) {
        values.append(count)
    }
}
