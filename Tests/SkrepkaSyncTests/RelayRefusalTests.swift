import Foundation
import Testing

@testable import SkrepkaSync

/// A peer that still records Universal Clipboard relays sends each one here as
/// new content. These are the two ways its bytes can arrive — inline with a
/// live push, and fetched after an exchange — and both have to discard it.
@Suite("Universal Clipboard relays from a peer")
struct RelayRefusalTests {
    private static let relayHash = String(repeating: "d", count: 64)
    private static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test("A pushed relay is neither stored nor put on the clipboard, and is tombstoned")
    func aPushedRelayIsDiscarded() async throws {
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

        let meta = Self.relayMeta(deviceID: harness.clientIdentity.deviceID, at: harness.now)
        async let served: Void = try responder.serve()
        try await initiator.push(meta, payloads: Self.relayPayloads)
        // Followed by something the responder does answer, so what is asserted
        // below is a push that was processed rather than one still in flight.
        try await pair.client.send(.ping(nonce: 1))
        #expect(try await pair.client.receive() == .ping(nonce: 1))

        #expect(await received.isEmpty())
        let index = await harness.serverStore.syncIndex(since: nil)
        #expect(!index.contains { $0.contentHash == Self.relayHash })
        let tombstones = await harness.serverStore.tombstones(since: nil)
        #expect(
            tombstones.contains {
                $0.contentHash == Self.relayHash && $0.deviceID == harness.serverIdentity.deviceID
            }
        )

        await pair.close()
        _ = try? await served
    }

    /// Rich text outranks a file URL, so its hash is its text — which the copy
    /// on the Mac it came from shares. Tombstoning it would remove that copy
    /// too, so only a file entry is ever judged a relay.
    @Test("A pushed rich-text copy that carries a staged file is kept, not tombstoned")
    func aPushedRichTextCopyIsKept() async throws {
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

        let meta = Self.relayMeta(
            kind: "richText", deviceID: harness.clientIdentity.deviceID, at: harness.now)
        async let served: Void = try responder.serve()
        try await initiator.push(meta, payloads: Self.relayPayloads)
        try await pair.client.send(.ping(nonce: 1))
        #expect(try await pair.client.receive() == .ping(nonce: 1))

        #expect(await received.first()?.meta.contentHash == Self.relayHash)
        let index = await harness.serverStore.syncIndex(since: nil)
        #expect(index.contains { $0.contentHash == Self.relayHash })
        #expect(await harness.serverStore.tombstones(since: nil).isEmpty)

        await pair.close()
        _ = try? await served
    }

    /// The index names a relay's file by display name alone, so the row lands
    /// and is judged once its bytes are fetched. The ordinary item beside it
    /// is the control: the check has to be specific to relays.
    @Test("A relay learned from an index is discarded once its bytes arrive")
    func aFetchedRelayIsDiscarded() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let relay = Self.relayMeta(deviceID: harness.serverIdentity.deviceID, at: harness.now)
        await harness.serverStore.capture(relay, payloads: Self.relayPayloads)

        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide)
        async let served: Void = try responder.serve()
        let initiator = try harness.initiator(
            for: pair.client, expecting: harness.serverIdentity.deviceID)
        _ = try await initiator.handshake()

        let clientStore = FakeHistoryStore()
        let runtime = SyncRuntime(
            certificate: harness.clientIdentity,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: harness.clientIdentity.deviceID,
                    deviceName: "client",
                    platform: .macos,
                    protocolVersion: .current
                ),
                localCertificate: harness.clientIdentity
            ),
            trust: harness.clientTrust,
            store: clientStore,
            group: harness.group
        )
        _ = try await SyncExchange(runtime: runtime, initiator: initiator).run()

        let index = await clientStore.syncIndex(since: nil).map(\.contentHash)
        #expect(index == [LoopbackHarness.contentHash])
        let tombstones = await clientStore.tombstones(since: nil)
        #expect(tombstones.map(\.contentHash) == [Self.relayHash])
        #expect(tombstones.first?.deviceID == harness.clientIdentity.deviceID)

        await pair.close()
        _ = try? await served
    }

    private static var relayPayloads: [RepresentationKey: Data] {
        [
            UniversalClipboardRelayTests.fileList: Data(
                UniversalClipboardRelayTests.staged.absoluteString.utf8),
            UniversalClipboardRelayTests.png: picture,
        ]
    }

    private static func relayMeta(
        kind: String = "imageFile",
        deviceID: SyncDeviceID,
        at now: Date
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: relayHash,
            kind: kind,
            preview: "CleanShot 2026-09-18 at 23.55.42@2x.png",
            createdAt: now,
            isPinned: LWWRegister(value: false, timestamp: now, deviceID: deviceID),
            imageWidth: 1298,
            imageHeight: 646,
            sourceBundleID: "com.apple.loginwindow",
            originDeviceID: deviceID,
            representations: relayPayloads.map {
                RepresentationDescriptor(key: $0.key, byteCount: $0.value.count)
            }
        )
    }
}
