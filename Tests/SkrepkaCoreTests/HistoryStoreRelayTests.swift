// The clean-up is SwiftData-only — see `HistoryStore+Relays.swift` for why.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    /// Earlier builds recorded every screenshot Universal Clipboard relayed from
    /// the other Mac as a file of its own, and synced it back. These are the
    /// rows the one-off clean-up has to find, and the ones it must leave.
    @Suite("Removing Universal Clipboard relays")
    @MainActor
    struct HistoryStoreRelayTests {
        private static let staged = URL(
            fileURLWithPath:
                "/Users/me/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/6E0E0FB1-07F4-4B58-A2BA-D793C68ECA07/shot.png"
        )
        private static let original = URL(
            fileURLWithPath: "/Users/me/Library/Application Support/CleanShot/media/media_x/shot.png"
        )
        private static let picture = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        private static let epoch = Date(timeIntervalSince1970: 900_000)

        @Test("Relays go, captured here or learned from a peer, and each leaves a tombstone")
        func removesRelaysWithTombstones() async throws {
            let store = try SyncFixtures.makeStore()
            #expect(await store.capture(Self.file(at: Self.staged, offset: 1)))
            try await store.capture(
                Self.meta("b", file: Self.staged, offset: 2), payloads: Self.wire(Self.staged))

            #expect(await store.removeUniversalClipboardRelays() == 2)
            #expect(store.items.isEmpty)
            let tombstones = try store.tombstones(since: nil)
            #expect(tombstones.count == 2)
            #expect(tombstones.allSatisfy { $0.deviceID == SyncFixtures.localDevice })
        }

        @Test("Originals, pinned relays and everything that is not a file stay")
        func keepsEverythingElse() async throws {
            let store = try SyncFixtures.makeStore()
            #expect(await store.capture(Self.file(at: Self.original, offset: 1)))
            try await store.capture(
                Self.meta("b", file: Self.original, offset: 2), payloads: Self.wire(Self.original))
            #expect(await store.capture(SyncFixtures.item("plain text", at: Self.epoch)))
            let relay = Self.file(at: Self.staged, offset: 3)
            #expect(await store.capture(relay))
            let pinned = try #require(store.items.first { $0.createdAt == relay.createdAt })
            store.togglePin(pinned.id)

            #expect(await store.removeUniversalClipboardRelays() == 0)
            #expect(store.items.count == 4)
            #expect(try store.tombstones(since: nil).isEmpty)
        }

        /// A file capture as `CaptureRules` builds one: the path, and the picture
        /// a screenshot app puts beside it.
        private static func file(at url: URL, offset: TimeInterval) -> ClipItem {
            ClipItem(
                kind: .file,
                text: url.lastPathComponent,
                payload: ClipPayload(
                    representations: [
                        PasteboardType.fileURL: Data(url.absoluteString.utf8),
                        PasteboardType.png: picture,
                    ]
                ),
                createdAt: epoch.addingTimeInterval(offset),
                fileURLs: [url]
            )
        }

        private static func wire(_ url: URL) -> [RepresentationKey: Data] {
            [
                RepresentationKey(canonical: "text/uri-list", origin: PasteboardType.fileURL):
                    Data(url.absoluteString.utf8),
                RepresentationKey(canonical: "image/png", origin: PasteboardType.png): picture,
            ]
        }

        /// A file row as a peer describes it. The hash is the peer's own and
        /// only has to be distinct here.
        private static func meta(_ hashSeed: String, file url: URL, offset: TimeInterval) -> SyncClipMeta {
            let createdAt = epoch.addingTimeInterval(offset)
            return SyncClipMeta(
                contentHash: String(repeating: hashSeed, count: 64),
                kind: ClipKind.imageFile.rawValue,
                preview: url.lastPathComponent,
                createdAt: createdAt,
                isPinned: LWWRegister(value: false, timestamp: createdAt, deviceID: SyncFixtures.peerDevice),
                originDeviceID: SyncFixtures.peerDevice,
                representations: wire(url).map {
                    RepresentationDescriptor(key: $0.key, byteCount: $0.value.count)
                }
            )
        }
    }

#endif
