import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// File copies on the way in — read whole at capture — and file rows from
/// another device as the history and the picker see them.
@Suite("File sync in the daemon's capture path and documents")
struct FileSyncDocumentTests {
    static let peer = String(repeating: "c", count: SyncDeviceID.hexLength)

    static func fileMeta(hash: String, withBundle: Bool) throws -> SyncClipMeta {
        let device = try #require(SyncDeviceID(hex: peer))
        let stamp = Date()
        var representations = [
            RepresentationDescriptor(
                key: RepresentationKey(canonical: "text/uri-list", origin: "public.file-url"), byteCount: 30)
        ]
        if withBundle { representations.append(RepresentationDescriptor(key: FileBundle.key, byteCount: 64)) }
        return SyncClipMeta(
            contentHash: hash,
            kind: ClipKind.file.rawValue,
            preview: "shot.png",
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: representations
        )
    }

    static let uriPayload = [
        RepresentationKey(canonical: "text/uri-list", origin: "public.file-url"):
            Data("file:///Users/philipp/shot.png".utf8)
    ]

    @Test("a submitted copy of several files is stored with every file's contents")
    func captureBundlesEveryFile() async throws {
        let (daemon, directory) = try ForeignFileWriteTests.daemon()
        let folder = directory.appending(path: "copied", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = folder.appending(path: "one.txt")
        let second = folder.appending(path: "two.txt")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let list = [first, second].map(\.absoluteString).joined(separator: "\r\n")

        let answer = await daemon.submit(
            SubmitRequest(representations: ["text/uri-list": Data(list.utf8).base64EncodedString()]))
        #expect(answer.ok)

        let entry = try #require(try await daemon.historyStore.listing().first)
        let contents = try #require(await daemon.historyStore.contents(for: entry.summary.id))
        let encoded = try #require(contents.payload.data(forType: FileBundle.storageType))
        let bundle = try FileBundle(encoded: encoded)
        #expect(bundle.files.map(\.name) == ["one.txt", "two.txt"])
        #expect(bundle.files.map(\.bytes) == [Data("one".utf8), Data("two".utf8)])
    }

    @Test("a foreign file row says whether its files came")
    func filesStatusIsReported() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let store = daemon.historyStore
        let file = FileBundle.File(name: "shot.png", bytes: Data("x".utf8))
        let bundle = try FileBundle(files: [file]).encoded()
        let synced = String(repeating: "1", count: 64)
        let pending = String(repeating: "2", count: 64)
        let names = String(repeating: "3", count: 64)
        try await store.capture(
            try Self.fileMeta(hash: synced, withBundle: true),
            payloads: Self.uriPayload.merging([FileBundle.key: bundle]) { held, _ in held })
        try await store.capture(try Self.fileMeta(hash: pending, withBundle: true), payloads: Self.uriPayload)
        try await store.capture(try Self.fileMeta(hash: names, withBundle: false), payloads: Self.uriPayload)

        let clips = await daemon.historyDocument(limit: 0).clips
        let status = Dictionary(clips.map { ($0.contentHash, $0.filesStatus) }) { first, _ in first }
        #expect(status[synced] == ClipDocument.FilesStatusName.synced)
        #expect(status[pending] == ClipDocument.FilesStatusName.pending)
        #expect(status[names] == ClipDocument.FilesStatusName.notSynced)
    }

    @Test("a synced picture file previews as its picture")
    func bundledPictureIsPreviewed() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let hash = String(repeating: "4", count: 64)
        let bundle = FileBundle(files: [FileBundle.File(name: "shot.png", bytes: ForeignFileWriteTests.png)])
        try await daemon.historyStore.capture(
            try Self.fileMeta(hash: hash, withBundle: true),
            payloads: Self.uriPayload.merging([FileBundle.key: try bundle.encoded()]) { held, _ in held })

        let clip = try #require(await daemon.historyDocument(limit: 0).clips.first)
        #expect(clip.hasPreview)
        let preview = await daemon.preview(.hash(hash), maxBytes: 0)
        #expect(preview.mediaType == "image/png")
    }

    @Test("received files live under the data directory when one is given, else the XDG cache")
    func cacheRoot() {
        var options = DaemonOptions()
        let home = URL(filePath: "/home/deck", directoryHint: .isDirectory)
        let root = options.fileCacheRoot(environment: [:], homeDirectory: home)
        #expect(root.path == "/home/deck/.cache/skrepka")
        #expect(
            options.fileCacheRoot(environment: ["XDG_CACHE_HOME": "/var/cache/me"], homeDirectory: home).path
                == "/var/cache/me/skrepka")
        #expect(
            options.fileCacheRoot(environment: ["XDG_CACHE_HOME": "relative"], homeDirectory: home).path
                == "/home/deck/.cache/skrepka")
        options.dataDirectory = URL(filePath: "/tmp/skrepka-test", directoryHint: .isDirectory)
        let scoped = options.fileCacheRoot(environment: [:], homeDirectory: home)
        #expect(scoped.path == "/tmp/skrepka-test/cache")
    }
}
