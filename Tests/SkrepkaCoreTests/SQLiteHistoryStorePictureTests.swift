// How the Linux store labels a picture file — one copied here, one copied here
// again, and one that arrived from a peer. The judging is ImageFileProbe's and
// is tested on both platforms in ImageFileProbeTests; this is what the store
// does with the answer.
#if os(Linux)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    @Suite("SQLite history store: picture files")
    struct SQLiteHistoryStorePictureTests {
        typealias Pictures = Fixtures.Pictures

        static func store() throws -> SQLiteHistoryStore {
            try SQLiteHistoryStore(
                location: nil, retention: .unlimited, localDeviceID: EngineFixtures.localDevice)
        }

        static func fileCopy(of url: URL) -> ClipItem {
            ClipItem(kind: .file, text: url.lastPathComponent, payload: Fixtures.fileURLPayload(url))
        }

        @Test("a picture file stored as an image file keeps its kind and size")
        func refinedCopyIsStoredAsItIs() async throws {
            let store = try Self.store()
            let url = try Pictures.write(Pictures.png, named: "shot.png")
            let item = await ImageFileProbe.refining(Self.fileCopy(of: url))

            #expect(await store.capture(item))
            let summary = try #require(try await store.summaries().first)
            #expect(summary.kind == .imageFile)
            #expect(summary.imageSize == ClipItem.ImageSize(width: 3, height: 2))
        }

        @Test("copying a picture recorded as a plain file again relabels the row, under the same hash")
        func repeatCopyRelabels() async throws {
            let store = try Self.store()
            let url = try Pictures.write(Pictures.jpegRotatedRight, named: "IMG_0001.jpg")
            let plain = Self.fileCopy(of: url)
            #expect(await store.capture(plain))
            #expect(try await store.summaries().first?.kind == .file)

            await store.capture(await ImageFileProbe.refining(plain))

            let summaries = try await store.summaries()
            #expect(summaries.count == 1)
            #expect(summaries.first?.kind == .imageFile)
            #expect(summaries.first?.imageSize == ClipItem.ImageSize(width: 2, height: 3))
        }

        @Test("a repeat copy that could not tell never turns an image file back into a file")
        func relabellingIsOneWay() async throws {
            let store = try Self.store()
            let url = try Pictures.write(Pictures.png, named: "shot.png")
            let plain = Self.fileCopy(of: url)
            #expect(await store.capture(await ImageFileProbe.refining(plain)))

            await store.capture(plain)
            #expect(try await store.summaries().first?.kind == .imageFile)
        }

        @Test("a peer's file row whose bundle holds a GIF is an image file here")
        func syncedGIFIsAnImageFile() async throws {
            let store = try Self.store()
            let stamp = EngineFixtures.at(1)
            let hash = String(repeating: "9", count: 64)
            let meta = SyncClipMeta(
                contentHash: hash,
                kind: ClipKind.file.rawValue,
                preview: "loop.gif",
                createdAt: stamp,
                isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: EngineFixtures.peerDevice),
                originDeviceID: EngineFixtures.peerDevice,
                representations: [RepresentationDescriptor(key: FileBundle.key, byteCount: 128)]
            )
            let bundle = FileBundle(files: [FileBundle.File(name: "loop.gif", bytes: Pictures.gif)])
            try await store.capture(meta, payloads: [FileBundle.key: try bundle.encoded()])

            let summary = try #require(try await store.summaries().first)
            #expect(summary.kind == .imageFile)
            #expect(summary.imageSize == ClipItem.ImageSize(width: 3, height: 2))
        }
    }

#endif
