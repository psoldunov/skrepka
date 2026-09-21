import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

@Suite("Pasteboard items for files received from a peer")
struct PasteboardFileItemsTests {
    static let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    static let urls = [
        URL(filePath: "/tmp/skrepka/files/a/one.txt"),
        URL(filePath: "/tmp/skrepka/files/a/two.txt"),
    ]

    static func twoFiles() -> FileBundle {
        FileBundle(files: [
            FileBundle.File(name: "one.txt", bytes: Data("1".utf8)),
            FileBundle.File(name: "two.txt", bytes: Data("2".utf8)),
        ])
    }

    @Test("Each file gets an item of its own, one URL apiece, as Finder writes them")
    func oneItemPerFile() {
        let clipboard = ForeignFileGuard.clipboard(forFilesAt: Self.urls, from: Self.twoFiles())
        let items = PasteboardFileItems.items(for: clipboard)

        #expect(items.count == 2)
        #expect(items[0][PasteboardType.fileURL] == Data(Self.urls[0].absoluteString.utf8))
        #expect(items[1] == [PasteboardType.fileURL: Data(Self.urls[1].absoluteString.utf8)])
    }

    @Test("The first item carries the names too, for an app that takes text")
    func firstItemCarriesNames() {
        let clipboard = ForeignFileGuard.clipboard(forFilesAt: Self.urls, from: Self.twoFiles())
        let head = PasteboardFileItems.items(for: clipboard)[0]
        #expect(head[PasteboardType.string] == Data("one.txt\ntwo.txt".utf8))
        #expect(head[FileBundle.storageType] == nil)
    }

    @Test("The names fallback is one item holding its text and no file")
    func namesAreOneItem() {
        let items = PasteboardFileItems.items(for: ForeignFileGuard.clipboard(forNames: "a.png\nb.png"))
        #expect(items == [[PasteboardType.string: Data("a.png\nb.png".utf8)]])
    }

    @Test("A JPEG picture gains the PNG it was given")
    func pngIsAdded() {
        let bundle = FileBundle(files: [FileBundle.File(name: "photo.jpg", bytes: Self.jpegHeader)])
        let clipboard = ForeignFileGuard.clipboard(forFilesAt: [Self.urls[0]], from: bundle)
        let png = Data([0x89, 0x50])

        #expect(PasteboardFileItems.pictureNeedingPNG(in: clipboard.payload) == Self.jpegHeader)
        let head = PasteboardFileItems.items(for: clipboard, png: png)[0]
        #expect(head[PasteboardType.jpeg] == Self.jpegHeader)
        #expect(head[PasteboardType.png] == png)
    }

    @Test("A PNG already there is kept, and nothing asks for another")
    func existingPNGIsKept() {
        let original = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9])
        let payload = ClipPayload(representations: [
            PasteboardType.png: original, PasteboardType.jpeg: Self.jpegHeader,
        ])
        #expect(PasteboardFileItems.pictureNeedingPNG(in: payload) == nil)

        let clipboard = ForeignFileGuard.Clipboard(payload: payload, fileURLs: [Self.urls[0]])
        let head = PasteboardFileItems.items(for: clipboard, png: Data([1]))[0]
        #expect(head[PasteboardType.png] == original)
    }

    @Test("Files that are not a picture ask for no PNG")
    func noPictureNoPNG() {
        let clipboard = ForeignFileGuard.clipboard(forFilesAt: Self.urls, from: Self.twoFiles())
        #expect(PasteboardFileItems.pictureNeedingPNG(in: clipboard.payload) == nil)
    }

    @Test("A local file row pastes without its bundle, and keeps everything else")
    func clipboardPayloadDropsBundle() {
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a.txt".utf8),
            FileBundle.storageType: Data(repeating: 7, count: 64),
        ])
        #expect(
            payload.forClipboard.representations == [
                PasteboardType.fileURL: Data("file:///Users/me/a.txt".utf8)
            ])
    }

    @Test(
        "A synced file row says so only when its files did not arrive",
        arguments: [
            (SyncedFilesStatus.synced, String?.none),
            (.pending, "contents not synced yet"),
            (.notSynced, "contents not synced"),
        ])
    func rowNote(status: SyncedFilesStatus, expected: String?) {
        #expect(status.rowNote == expected)
    }
}

#if canImport(AppKit)
    extension PasteboardFileItemsTests {
        @Test("A JPEG re-encodes as an upright PNG")
        func transcodesJPEG() throws {
            // Orientation 6 stores the picture on its side; upright, 30 × 20
            // stored reads 20 × 30.
            let url = try Fixtures.writeJPEG(width: 30, height: 20, orientation: 6, named: "photo.jpg")
            let png = try #require(PasteboardFileItems.pngTranscode(of: try Data(contentsOf: url)))

            #expect(ImageSignature(sniffing: png) == .png)
            let size = try #require(ImageSignature.png.pixelSize(of: png))
            #expect(size.width == 20 && size.height == 30)
        }

        @Test("A picture declaring more pixels than the budget is not decoded")
        func refusesOverBudget() throws {
            let url = try Fixtures.writeJPEG(width: 30, height: 20, orientation: 1, named: "small.jpg")
            let jpeg = try Data(contentsOf: url)
            #expect(PasteboardFileItems.pngTranscode(of: jpeg, pixelBudget: 599) == nil)
            #expect(PasteboardFileItems.pngTranscode(of: jpeg, pixelBudget: 600) != nil)
        }

        @Test("Bytes that are no picture give no PNG")
        func refusesGarbage() {
            #expect(PasteboardFileItems.pngTranscode(of: Self.jpegHeader) == nil)
        }
    }
#endif
