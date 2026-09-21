import Foundation
import Testing

@testable import SkrepkaSync

/// A file bundle is offered only to a peer that promised to keep one.
///
/// The failure this prevents is invisible from either end: a 0.2 peer offered
/// a bundle stores the item without it, finds it missing on the next exchange,
/// and fetches it again — every thirty seconds, for as long as they are paired.
@Suite("The files capability")
struct FileCapabilityTests {
    private static let fileHash = String(repeating: "f", count: 64)

    @Test("The filter strips the bundle from what an incapable peer sees, and nothing else")
    func filterStripsOnlyTheBundle() throws {
        let item = try Self.fileItem(from: SyncFixtures.deviceA, at: SyncFixtures.epoch)

        let stripped = CapabilityFilter.none.meta(item.meta)
        #expect(stripped.contentHash == item.meta.contentHash)
        #expect(stripped.representations.map(\.key) == [FileSyncFixtures.fileURLKey])
        #expect(CapabilityFilter.none.payloads(item.payloads).keys.sorted() == [FileSyncFixtures.fileURLKey])

        let capable = CapabilityFilter(capabilities: SyncCapability.local)
        #expect(capable.meta(item.meta) == item.meta)
        #expect(capable.payloads(item.payloads) == item.payloads)
    }

    @Test("This build advertises files")
    func localCapabilitiesIncludeFiles() {
        #expect(SyncCapability.local.contains(SyncCapability.files))
    }

    @Test("An index is offered with the bundle only to a peer that advertised files")
    func indexOfferRespectsCapability() async throws {
        for (capabilities, expectsBundle) in [([String](), false), (SyncCapability.local, true)] {
            let harness = try await LoopbackHarness()
            defer { harness.shutdown() }
            let item = try Self.fileItem(from: harness.serverIdentity.deviceID, at: harness.now)
            await harness.serverStore.capture(item.meta, payloads: item.payloads)

            let pair = try await harness.connectedPair(
                serverPolicy: .pinned([harness.clientIdentity.deviceID]),
                clientPolicy: .pinned([harness.serverIdentity.deviceID])
            )
            let responder = harness.responder(for: pair.serverSide)
            async let served: Void = try responder.serve()
            let initiator = try harness.initiator(
                for: pair.client, expecting: harness.serverIdentity.deviceID, capabilities: capabilities)
            _ = try await initiator.handshake()

            let offer = try await initiator.requestIndex(since: nil)
            let offered = try #require(offer.items.first { $0.contentHash == Self.fileHash })
            #expect(offered.representations.contains { $0.key == FileBundle.key } == expectsBundle)

            await pair.close()
            _ = try? await served
        }
    }

    @Test("A 0.2 peer fetches a file item's bytes once, not every exchange")
    func anOldPeerDoesNotLoop() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let item = try Self.fileItem(from: harness.serverIdentity.deviceID, at: harness.now)
        await harness.serverStore.capture(item.meta, payloads: item.payloads)

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide, capabilities: SyncCapability.local)
        async let served: Void = try responder.serve()
        // A 0.2 client advertises nothing.
        let initiator = try harness.initiator(for: pair.client, expecting: harness.serverIdentity.deviceID)
        _ = try await initiator.handshake()

        let oldStore = OldPeerStore()
        let runtime = Self.runtime(harness: harness, store: oldStore)
        for _ in 0..<3 {
            _ = try await SyncExchange(runtime: runtime, initiator: initiator).run()
        }
        // The text item and the file item, once each.
        #expect(await oldStore.capturesWithBytes == 2)

        await pair.close()
        _ = try? await served
    }

    @Test("A capable peer fetches the bundle and keeps it")
    func aCapablePeerReceivesTheBundle() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let bundle = try FileSyncFixtures.bundle()
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

        let clientStore = FakeHistoryStore()
        let fetched = FetchedItems()
        let runtime = Self.runtime(harness: harness, store: clientStore)
        _ = try await SyncExchange(runtime: runtime, initiator: initiator, onFetched: fetched.record).run()
        _ = try await SyncExchange(runtime: runtime, initiator: initiator, onFetched: fetched.record).run()

        #expect(await clientStore.payload(for: Self.fileHash, key: FileBundle.key) == bundle)
        // Once: the second exchange found nothing missing.
        #expect(await fetched.hashes().filter { $0 == Self.fileHash }.count == 1)

        await pair.close()
        _ = try? await served
    }

    @Test("A push to a peer that has not advertised files carries no bundle")
    func aPushIsFilteredByCapability() async throws {
        for (capabilities, expectsBundle) in [([String](), false), (SyncCapability.local, true)] {
            let harness = try await LoopbackHarness()
            defer { harness.shutdown() }
            let pair = try await harness.connectedPair(
                serverPolicy: .pinned([harness.clientIdentity.deviceID]),
                clientPolicy: .pinned([harness.serverIdentity.deviceID])
            )
            let received = ReceivedPushes()
            let responder = harness.responder(
                for: pair.serverSide, onLivePush: received.record, capabilities: capabilities)
            async let served: Void = try responder.serve()
            let initiator = try harness.initiator(
                for: pair.client, expecting: harness.serverIdentity.deviceID)
            _ = try await initiator.handshake()

            let item = try Self.fileItem(from: harness.clientIdentity.deviceID, at: harness.now)
            try await initiator.push(item.meta, payloads: item.payloads)

            let arrival = try await harness.eventually { await received.first() }
            #expect(arrival.meta.representations.contains { $0.key == FileBundle.key } == expectsBundle)
            #expect((arrival.inline[FileBundle.key] != nil) == expectsBundle)
            #expect(arrival.inline[FileSyncFixtures.fileURLKey] != nil)

            await pair.close()
            _ = try? await served
        }
    }

    private static func fileItem(
        from deviceID: SyncDeviceID,
        at date: Date
    ) throws -> (meta: SyncClipMeta, payloads: [RepresentationKey: Data]) {
        FileSyncFixtures.fileItem(
            fileHash, bundle: try FileSyncFixtures.bundle(), deviceID: deviceID, at: date)
    }

    static func runtime(harness: LoopbackHarness, store: any HistoryStoring) -> SyncRuntime {
        SyncRuntime(
            certificate: harness.clientIdentity,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: harness.clientIdentity.deviceID,
                    deviceName: "client",
                    platform: .linux,
                    protocolVersion: .current
                ),
                localCertificate: harness.clientIdentity
            ),
            trust: harness.clientTrust,
            store: store,
            group: harness.group
        )
    }
}
