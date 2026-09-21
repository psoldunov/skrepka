import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

#if canImport(AppKit)
    import AppKit
#endif

/// File bundles through both stores: kept, offered, served, pictured, and
/// cleaned up with their rows.
extension HistoryStoringTests {
    static let bundleDescriptorKey = FileBundle.key

    @Test("A local file copy's bundle is kept, offered and served", arguments: HistoryStoreEngine.all)
    func localBundleIsOffered(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let url = try Fixtures.writeTextFile("contents", named: "note.txt")
        let item = await FileBundleReader.attachingBundle(
            to: ClipItem(kind: .file, text: "note.txt", payload: Fixtures.fileURLPayload(url)))
        #expect(await store.capture(item))

        let offered = try #require(try await store.syncIndex(since: nil).first)
        #expect(offered.representations.contains { $0.key.canonical == FileBundle.canonicalKey })
        let served = try await store.payload(for: item.contentHash, key: Self.bundleDescriptorKey)
        #expect(served == item.payload.data(forType: FileBundle.storageType))
    }

    @Test("A peer's bundle is kept, and offered on", arguments: HistoryStoreEngine.all)
    func peerBundleIsKept(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let bundle = try FileBundle(files: [FileBundle.File(name: "a.txt", bytes: Data("a".utf8))]).encoded()
        let meta = Self.fileMeta(hash: String(repeating: "e", count: 64), bundle: bundle)
        try await store.capture(meta, payloads: [Self.bundleDescriptorKey: bundle])

        #expect(try await store.payload(for: meta.contentHash, key: Self.bundleDescriptorKey) == bundle)
        let offered = try #require(try await store.syncIndex(since: nil).first)
        #expect(offered.representations.contains { $0.key.canonical == FileBundle.canonicalKey })
        #expect(try await store.summaries().first?.kind == .file)
    }

    @Test("A peer's bundled picture reads as an image, with its size", arguments: HistoryStoreEngine.all)
    func bundledPictureIsAnImage(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let picture = try Self.picture(width: 12, height: 8)
        let bundle = try FileBundle(files: [FileBundle.File(name: "shot.png", bytes: picture)]).encoded()
        let meta = Self.fileMeta(hash: String(repeating: "d", count: 64), bundle: bundle)
        try await store.capture(meta, payloads: [Self.bundleDescriptorKey: bundle])

        let row = try #require(try await store.summaries().first)
        #expect(row.kind == .imageFile)
        #expect(row.imageSize == ClipItem.ImageSize(width: 12, height: 8))
    }

    @Test("Deleting a row removes its received files", arguments: HistoryStoreEngine.all)
    func deletionSweepsFiles(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let cache = FileCache(root: try Fixtures.makeDirectory())
        await store.setFileCache(cache)
        #expect(await store.capture(EngineFixtures.item("kept", at: EngineFixtures.at(1))))
        #expect(await store.capture(EngineFixtures.item("gone", at: EngineFixtures.at(2))))
        try Self.materialize(for: EngineFixtures.contentHash("kept"), in: cache)
        try Self.materialize(for: EngineFixtures.contentHash("gone"), in: cache)

        let doomed = try #require(try await store.summaries().first { $0.text == "gone" })
        await store.delete(doomed.id)
        #expect(cache.entries() == [EngineFixtures.contentHash("kept")])
    }

    @Test("Evicting a row removes its received files", arguments: HistoryStoreEngine.all)
    func evictionSweepsFiles(engine: HistoryStoreEngine) async throws {
        let retention = RetentionPolicy(maximumItems: 1, maximumAge: nil)
        let store = try await Self.makeStore(engine, retention: retention)
        let cache = FileCache(root: try Fixtures.makeDirectory())
        await store.setFileCache(cache)
        #expect(await store.capture(EngineFixtures.item("first", at: EngineFixtures.at(1))))
        try Self.materialize(for: EngineFixtures.contentHash("first"), in: cache)

        #expect(await store.capture(EngineFixtures.item("second", at: EngineFixtures.at(2))))
        #expect(cache.entries().isEmpty)
    }

    @Test("A launch sweep removes files no row owns", arguments: HistoryStoreEngine.all)
    func launchSweep(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let cache = FileCache(root: try Fixtures.makeDirectory())
        #expect(await store.capture(EngineFixtures.item("kept", at: EngineFixtures.at(1))))
        try Self.materialize(for: EngineFixtures.contentHash("kept"), in: cache)
        try Self.materialize(for: String(repeating: "0", count: 64), in: cache)

        #expect(await store.sweepFileCache() == 0)
        await store.setFileCache(cache)
        #expect(await store.sweepFileCache() == 1)
        #expect(cache.entries() == [EngineFixtures.contentHash("kept")])
    }

    @Test(
        "A file edited in place and copied again is a new row with the new bytes",
        arguments: HistoryStoreEngine.all)
    func editedFileIsANewRow(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let url = try Fixtures.writeTextFile("first shot", named: "shot.txt")
        let copy = { ClipItem(kind: .file, text: "shot.txt", payload: Fixtures.fileURLPayload(url)) }

        let first = await FileBundleReader.attachingBundle(to: copy())
        #expect(await store.capture(first))
        #expect(await store.capture(await FileBundleReader.attachingBundle(to: copy())))
        #expect(try await store.summaries().count == 1)

        try Data("second shot".utf8).write(to: url)
        let second = await FileBundleReader.attachingBundle(to: copy())
        #expect(await store.capture(second))
        #expect(try await store.summaries().count == 2)
        let served = try await store.payload(for: second.contentHash, key: Self.bundleDescriptorKey)
        let bundle = try FileBundle(encoded: try #require(served))
        #expect(bundle.files.first?.bytes == Data("second shot".utf8))
    }

    // MARK: - Fixtures

    private static func fileMeta(hash: String, bundle: Data) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: hash,
            kind: ClipKind.file.rawValue,
            preview: "shot.png",
            createdAt: EngineFixtures.at(5),
            isPinned: LWWRegister(
                value: false, timestamp: EngineFixtures.at(5), deviceID: EngineFixtures.peerDevice),
            originDeviceID: EngineFixtures.peerDevice,
            representations: [RepresentationDescriptor(key: bundleDescriptorKey, byteCount: bundle.count)]
        )
    }

    private static func materialize(for contentHash: String, in cache: FileCache) throws {
        _ = try FileMaterializer.materialize(
            FileBundle(files: [FileBundle.File(name: "a", bytes: Data("a".utf8))]),
            contentHash: contentHash,
            in: cache
        )
    }

    /// A picture each engine can measure: a real PNG where AppKit decodes one,
    /// and a bare header on Linux, whose store reads nothing but the header.
    private static func picture(width: Int, height: Int) throws -> Data {
        #if canImport(AppKit)
            try Fixtures.png(width: width, height: height)
        #else
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8))
                + Data([0, 0, 0, UInt8(width), 0, 0, 0, UInt8(height), 8, 6, 0, 0, 0])
        #endif
    }
}
