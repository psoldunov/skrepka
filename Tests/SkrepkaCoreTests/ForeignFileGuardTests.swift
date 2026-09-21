import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

@Suite("What a foreign file row may put on the clipboard")
struct ForeignFileGuardTests {
    static let foreignPath = Data("file:///home/deck/Pictures/shot.png".utf8)
    static let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    static func bundled(_ files: [FileBundle.File]) throws -> [String: Data] {
        [PasteboardType.fileURL: foreignPath, FileBundle.storageType: try FileBundle(files: files).encoded()]
    }

    @Test("A row with a bundle pastes as its files")
    func bundlePastesAsFiles() throws {
        let files = [FileBundle.File(name: "shot.png", bytes: Self.pngHeader)]
        let decision = ForeignFileGuard.decide(
            kind: .file, representations: try Self.bundled(files), preview: "shot.png", isForeign: true)
        #expect(decision == .files(FileBundle(files: files)))
    }

    @Test("A row without one pastes its names, never the foreign path")
    func noBundlePastesNames() {
        let decision = ForeignFileGuard.decide(
            kind: .file,
            representations: [PasteboardType.fileURL: Self.foreignPath],
            preview: "x",
            isForeign: true
        )
        #expect(decision == .names("shot.png"))
        let clipboard = ForeignFileGuard.clipboard(forNames: "shot.png")
        #expect(clipboard.payload.representations.keys.sorted() == [PasteboardType.string])
        #expect(clipboard.fileURLs.isEmpty)
    }

    @Test("A Linux peer's list of several files pastes all their names")
    func uriListNames() {
        let list = Data("# copied\r\nfile:///home/deck/a%20b.txt\r\nfile:///home/deck/c.txt\r\n".utf8)
        let decision = ForeignFileGuard.decide(
            kind: .file, representations: [PasteboardType.fileURL: list], preview: "fallback", isForeign: true
        )
        #expect(decision == .names("a b.txt\nc.txt"))
    }

    @Test("With nothing readable, the row's own text names the files")
    func previewFallback() {
        let decision = ForeignFileGuard.decide(
            kind: .folder, representations: [:], preview: "Projects", isForeign: true)
        #expect(decision == .names("Projects"))
    }

    @Test("A bundle that will not decode is treated as no bundle")
    func corruptBundle() {
        let decision = ForeignFileGuard.decide(
            kind: .file,
            representations: [
                PasteboardType.fileURL: Self.foreignPath, FileBundle.storageType: Data([0xFF]),
            ],
            preview: "x",
            isForeign: true
        )
        #expect(decision == .names("shot.png"))
    }

    @Test("A local row, or a row that is not a file, passes through")
    func passThrough() throws {
        let representations = try Self.bundled([FileBundle.File(name: "a", bytes: Data())])
        #expect(
            ForeignFileGuard.decide(
                kind: .file, representations: representations, preview: "", isForeign: false)
                == .passThrough)
        #expect(
            ForeignFileGuard.decide(kind: .text, representations: [:], preview: "hi", isForeign: true)
                == .passThrough)
    }

    @Test("Materialised files paste as local URLs, names, and the picture when there is one")
    func clipboardForFiles() throws {
        let urls = [URL(fileURLWithPath: "/tmp/cache/files/x/shot.png")]
        let bundle = FileBundle(files: [FileBundle.File(name: "shot.png", bytes: Self.pngHeader)])
        let clipboard = ForeignFileGuard.clipboard(forFilesAt: urls, from: bundle)
        #expect(clipboard.fileURLs == urls)
        #expect(clipboard.payload.fileURL == urls[0])
        #expect(clipboard.payload.data(forType: PasteboardType.png) == Self.pngHeader)
        #expect(clipboard.payload.data(forType: PasteboardType.string) == Data("shot.png".utf8))
        #expect(clipboard.payload.data(forType: FileBundle.storageType) == nil)

        let two = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b")]
        let list = ForeignFileGuard.clipboard(forFilesAt: two, from: FileBundle(files: []))
        #expect(
            list.payload.data(forType: PasteboardType.fileURL) == Data("file:///tmp/a\r\nfile:///tmp/b".utf8))
        #expect(list.payload.data(forType: PasteboardType.png) == nil)
    }

    @Test("A row says whether its files came with it")
    func status() {
        let bundle: Set<String> = [PasteboardType.fileURL, FileBundle.storageType]
        let path: Set<String> = [PasteboardType.fileURL]
        #expect(
            SyncedFilesStatus.of(kind: .file, isForeign: true, offeredTypes: bundle, heldTypes: bundle)
                == .synced)
        #expect(
            SyncedFilesStatus.of(kind: .file, isForeign: true, offeredTypes: bundle, heldTypes: path)
                == .pending)
        #expect(
            SyncedFilesStatus.of(kind: .folder, isForeign: true, offeredTypes: path, heldTypes: path)
                == .notSynced)
        #expect(
            SyncedFilesStatus.of(kind: .file, isForeign: false, offeredTypes: path, heldTypes: path) == nil)
        #expect(SyncedFilesStatus.of(kind: .text, isForeign: true, offeredTypes: [], heldTypes: []) == nil)
    }
}

@Suite("The bundle stays off the clipboard")
struct ClipPayloadForClipboardTests {
    @Test("A payload written to a clipboard carries everything but the bundle")
    func bundleIsStripped() {
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///a".utf8),
            FileBundle.storageType: Data([1, 2, 3]),
        ])
        #expect(payload.forClipboard.representations.keys.sorted() == [PasteboardType.fileURL])
        let plain = ClipPayload(representations: [PasteboardType.string: Data("hi".utf8)])
        #expect(plain.forClipboard == plain)
    }
}
