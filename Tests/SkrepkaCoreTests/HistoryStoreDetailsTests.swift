import Foundation
import Testing

@testable import SkrepkaCore

/// What the off-actor detail pass — see `ThumbnailRenderer` — puts on a row:
/// the preview, the measured size, and the corrections a repeat copy applies to
/// an entry stored before either existed.
@Suite("History store details")
@MainActor
struct HistoryStoreDetailsTests {
    private func makeStore() throws -> HistoryStore {
        try HistoryStore(location: nil, retention: .unlimited)
    }

    @Test("An image copied as data gets a row thumbnail")
    func thumbnailsImageData() async throws {
        let store = try makeStore()
        let payload = ClipPayload(representations: [
            PasteboardType.png: try Fixtures.png(width: 300, height: 150)
        ])
        await store.capture(ClipItem(kind: .image, text: "", payload: payload))

        let summary = try #require(store.items.first)
        #expect(summary.thumbnail != nil)
        #expect(summary.imageSize == ClipItem.ImageSize(width: 300, height: 150))
    }

    @Test("An image copied as a file gets a row thumbnail too")
    func thumbnailsImageFile() async throws {
        let store = try makeStore()
        let url = try Fixtures.writePNG(width: 800, height: 600, named: "shot.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await store.capture(
            ClipItem(kind: .file, text: "shot.png", payload: Fixtures.fileURLPayload(url))
        )

        let summary = try #require(store.items.first)
        #expect(summary.thumbnail != nil)
        #expect(summary.imageSize == ClipItem.ImageSize(width: 800, height: 600))
    }

    @Test("A copied document gets no thumbnail and falls back to its kind symbol")
    func skipsNonImageFile() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data("not an image".utf8).write(to: url)
        await store.capture(
            ClipItem(kind: .file, text: "notes.txt", payload: Fixtures.fileURLPayload(url))
        )

        let summary = try #require(store.items.first)
        #expect(summary.thumbnail == nil)
        #expect(summary.imageSize == nil)
    }

    @Test("A captured file carries its size into the row")
    func storesFileSize() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "notes.txt", directoryHint: .notDirectory)
        try Data(repeating: 0x41, count: 2048).write(to: url)

        await store.capture(
            ClipItem(kind: .file, text: "notes.txt", payload: Fixtures.fileURLPayload(url))
        )
        #expect(store.items.first?.byteCount == 2048)
        #expect(store.items.first?.sizeText == "2 kB")
    }

    @Test("Re-copying measures a size the first capture could not take")
    func backfillsSizeOnRepeatCopy() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "late.bin", directoryHint: .notDirectory)

        // Nothing at the path yet, which is also the state of every entry
        // stored before sizes were measured at all.
        let item = ClipItem(kind: .file, text: "late.bin", payload: Fixtures.fileURLPayload(url))
        await store.capture(item)
        #expect(store.items.first?.byteCount == nil)

        try Data(repeating: 0x41, count: 300).write(to: url)
        await store.capture(item)
        #expect(store.items.count == 1)
        #expect(store.items.first?.byteCount == 300)
    }

    @Test("A size already taken survives a re-copy that cannot measure")
    func keepsSizeWhenRemeasureFails() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "moved.bin", directoryHint: .notDirectory)
        try Data(repeating: 0x41, count: 300).write(to: url)

        let item = ClipItem(kind: .file, text: "moved.bin", payload: Fixtures.fileURLPayload(url))
        await store.capture(item)
        #expect(store.items.first?.byteCount == 300)

        // The row is a snapshot of the copy that made it; a file moved since
        // should not blank the size it was copied at.
        try FileManager.default.removeItem(at: url)
        await store.capture(item)
        #expect(store.items.first?.byteCount == 300)
    }

    @Test("Re-copying a folder corrects a row still labelled File")
    func healsStaleFileKindOnRepeatCopy() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Fixtures.fileURLPayload(directory)

        // What a history stored before folders were told apart holds.
        await store.capture(ClipItem(kind: .file, text: "Nextcloud", payload: payload))
        #expect(store.items.first?.kind == .file)

        await store.capture(ClipItem(kind: .folder, text: "Nextcloud", payload: payload))
        #expect(store.items.count == 1)
        #expect(store.items.first?.kind == .folder)
    }

    @Test("Re-copying fills in a thumbnail the first capture could not make")
    func backfillsThumbnailOnRepeatCopy() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "shot.png", directoryHint: .notDirectory)

        // Captured with nothing at the path, so there is no picture to preview.
        // Same end state as every entry stored before `.file` earned previews:
        // a row with a document icon and no thumbnail.
        let item = ClipItem(kind: .file, text: "shot.png", payload: Fixtures.fileURLPayload(url))
        await store.capture(item)
        #expect(store.items.first?.thumbnail == nil)

        try Fixtures.png(width: 320, height: 240).write(to: url)
        await store.capture(item)

        let summary = try #require(store.items.first)
        #expect(store.items.count == 1)
        #expect(summary.thumbnail != nil)
        #expect(summary.imageSize == ClipItem.ImageSize(width: 320, height: 240))
    }
}
