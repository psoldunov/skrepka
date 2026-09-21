// Exercises the SwiftData store, so it is fenced off Linux like the store is.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    @Suite("Who recorded a file row, and whether its files came")
    @MainActor
    struct HistoryStoreForeignFilesTests {
        static let hash = String(repeating: "c", count: 64)

        static func fileMeta(offering representations: [RepresentationDescriptor]) -> SyncClipMeta {
            let date = Date(timeIntervalSince1970: 1_000_000)
            return SyncClipMeta(
                contentHash: hash,
                kind: ClipKind.file.rawValue,
                preview: "shot.png",
                createdAt: date,
                isPinned: LWWRegister(value: false, timestamp: date, deviceID: SyncFixtures.peerDevice),
                originDeviceID: SyncFixtures.peerDevice,
                representations: representations
            )
        }

        static func bundle() throws -> Data {
            try FileBundle(files: [FileBundle.File(name: "shot.png", bytes: Data("x".utf8))]).encoded()
        }

        static func captureLocalFile(into store: HistoryStore) async throws -> UUID {
            let url = try Fixtures.writeTextFile("contents", named: "note.txt")
            let item = await FileBundleReader.attachingBundle(
                to: ClipItem(kind: .file, text: "note.txt", payload: Fixtures.fileURLPayload(url)))
            #expect(await store.capture(item))
            return try #require(store.items.first?.id)
        }

        @Test("A file this Mac copied is its own, and says nothing about syncing")
        func localFileIsLocal() async throws {
            let store = try SyncFixtures.makeStore()
            let id = try await Self.captureLocalFile(into: store)

            #expect(store.origin(for: id)?.isForeign == false)
            #expect(store.syncedFilesStatus(for: id) == nil)
        }

        @Test("A peer's file row with no bundle is foreign and not synced")
        func peerRowWithoutBundle() async throws {
            let store = try SyncFixtures.makeStore()
            let fileURL = RepresentationKey(canonical: "text/uri-list", origin: PasteboardType.fileURL)
            try await store.capture(
                Self.fileMeta(offering: [RepresentationDescriptor(key: fileURL, byteCount: 20)]),
                payloads: [:])
            let id = try #require(store.items.first?.id)

            #expect(store.origin(for: id) == HistoryStore.RowOrigin(contentHash: Self.hash, isForeign: true))
            #expect(store.syncedFilesStatus(for: id) == .notSynced)
        }

        @Test("A peer's offered bundle is pending until its bytes land")
        func peerBundlePendingThenSynced() async throws {
            let store = try SyncFixtures.makeStore()
            let bundle = try Self.bundle()
            let meta = Self.fileMeta(offering: [
                RepresentationDescriptor(key: FileBundle.key, byteCount: bundle.count)
            ])
            try await store.capture(meta, payloads: [:])
            let id = try #require(store.items.first?.id)
            #expect(store.syncedFilesStatus(for: id) == .pending)

            try await store.capture(meta, payloads: [FileBundle.key: bundle])
            #expect(store.syncedFilesStatus(for: id) == .synced)
        }

        @Test("A peer's bundle over this Mac's limit says so, and is pending again under a higher one")
        func peerBundleOverLimit() async throws {
            let store = try SyncFixtures.makeStore()
            let bundle = try Self.bundle()
            let meta = Self.fileMeta(offering: [
                RepresentationDescriptor(key: FileBundle.key, byteCount: bundle.count)
            ])
            try await store.capture(meta, payloads: [:])
            let id = try #require(store.items.first?.id)
            #expect(store.syncedFilesStatus(for: id, fileLimit: bundle.count - 1) == .overLimit)
            #expect(store.syncedFilesStatus(for: id, fileLimit: bundle.count) == .pending)
            #expect(store.entryID(forContentHash: Self.hash) == id)
            #expect(store.entryID(forContentHash: String(repeating: "0", count: 64)) == nil)
        }

        @Test("Before sync loads this Mac's identity, a local copy is still local")
        func unknownIdentityFallsBackToFileList() async throws {
            let store = try SyncFixtures.makeStore()
            let localID = try await Self.captureLocalFile(into: store)
            try await store.capture(
                Self.fileMeta(offering: [RepresentationDescriptor(key: FileBundle.key, byteCount: 10)]),
                payloads: [:])
            let peerID = try #require(store.items.first { $0.id != localID }?.id)

            store.localDeviceID = nil
            #expect(store.origin(for: localID)?.isForeign == false)
            #expect(store.origin(for: peerID)?.isForeign == true)
        }
    }

#endif
