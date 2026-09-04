import AppKit
import Foundation
import Testing

@testable import ClippyCore

@Suite("Thumbnail maker")
struct ThumbnailMakerTests {
    private let maker = ThumbnailMaker()

    @Test("Image data on the pasteboard yields a preview at the original's pixel size")
    func previewsRawImageData() throws {
        let payload = ClipPayload(representations: [
            PasteboardType.png: try Fixtures.png(width: 400, height: 200)
        ])

        let preview = try #require(maker.makePreview(from: payload))
        #expect(NSImage(data: preview.thumbnail) != nil)
        #expect(preview.pixelSize == ClipItem.ImageSize(width: 400, height: 200))
    }

    @Test("A copied image file is previewed from the file it points at")
    func previewsReferencedImageFile() throws {
        let url = try Fixtures.writePNG(width: 640, height: 480, named: "shot.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
        #expect(NSImage(data: preview.thumbnail) != nil)
        #expect(preview.pixelSize == ClipItem.ImageSize(width: 640, height: 480))
    }

    @Test("The generated thumbnail is bounded by the maximum edge")
    func boundsThumbnailSize() throws {
        let url = try Fixtures.writePNG(width: 2048, height: 1024, named: "wide.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
        let rep = try #require(NSImage(data: preview.thumbnail)?.representations.first)
        #expect(rep.pixelsWide <= Int(ThumbnailMaker.maximumEdge))
        #expect(rep.pixelsHigh <= Int(ThumbnailMaker.maximumEdge))
    }

    @Test("A copied non-image file gets no preview")
    func skipsNonImageFile() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("not an image".utf8).write(to: url)

        #expect(maker.makePreview(from: Fixtures.fileURLPayload(url)) == nil)
    }

    @Test("A file URL pointing nowhere gets no preview")
    func skipsMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/clippy-does-not-exist-\(UUID().uuidString).png")
        #expect(maker.makePreview(from: Fixtures.fileURLPayload(url)) == nil)
    }

    @Test("Image data wins over the file URL beside it, so nothing is read off disk")
    func prefersInlineImageDataOverTheFile() throws {
        let url = URL(fileURLWithPath: "/tmp/clippy-does-not-exist-\(UUID().uuidString).png")
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data(url.absoluteString.utf8),
            PasteboardType.png: try Fixtures.png(width: 120, height: 60),
        ])

        let preview = try #require(maker.makePreview(from: payload))
        #expect(preview.pixelSize == ClipItem.ImageSize(width: 120, height: 60))
    }

    @Test("Text-only content has nothing to preview")
    func skipsText() {
        let payload = ClipPayload(representations: [PasteboardType.string: Data("hello".utf8)])
        #expect(maker.makePreview(from: payload) == nil)
    }

    @Test("An EXIF-rotated photo reports the dimensions it is shown at")
    func reportsOrientedDimensions() throws {
        // Orientation 6 stores the picture landscape and asks a reader for a
        // quarter turn, so 640 × 480 on disk is a 480 × 640 portrait on screen.
        // This is the shape every photo taken on a phone held upright arrives in.
        let url = try Fixtures.writeJPEG(
            width: 640,
            height: 480,
            orientation: 6,
            named: "upright.jpg"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
        #expect(preview.pixelSize == ClipItem.ImageSize(width: 480, height: 640))

        // And the thumbnail really is portrait, so the subtitle and the picture
        // agree rather than both being wrong in the same direction.
        let rep = try #require(NSImage(data: preview.thumbnail)?.representations.first)
        #expect(rep.pixelsHigh > rep.pixelsWide)
    }

    @Test("An unrotated photo reports its stored dimensions unchanged")
    func leavesUnrotatedDimensionsAlone() throws {
        let url = try Fixtures.writeJPEG(
            width: 640,
            height: 480,
            orientation: 1,
            named: "level.jpg"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let preview = try #require(maker.makePreview(from: Fixtures.fileURLPayload(url)))
        #expect(preview.pixelSize == ClipItem.ImageSize(width: 640, height: 480))
    }

    @Test("A copied folder gets no preview")
    func skipsDirectory() throws {
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(maker.makePreview(from: Fixtures.fileURLPayload(directory)) == nil)
    }
}
