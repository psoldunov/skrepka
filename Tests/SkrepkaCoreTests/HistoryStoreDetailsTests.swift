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
        // Locale pinned: `ByteCountFormatStyle` renders units and separators in
        // the reader's language, so an unpinned assertion is a test that fails
        // on a Mac set to French.
        #expect(store.items.first?.sizeText(locale: Locale(identifier: "en_US")) == "2 kB")
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

    // MARK: - Folder kind

    /// What the capture rules hand the store for any file URL: `.file`,
    /// whatever is at the end of it. Only the detail pass can say otherwise.
    private func fileItem(_ url: URL) -> ClipItem {
        ClipItem(kind: .file, text: url.lastPathComponent, payload: Fixtures.fileURLPayload(url))
    }

    @Test("A copied folder is stored as .folder even though capture said .file")
    func refinesFolderKind() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "Nextcloud", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await store.capture(fileItem(folder))
        #expect(store.items.first?.kind == .folder)
    }

    @Test("Re-copying a folder corrects a row still labelled File")
    func healsStaleFileKindOnRepeatCopy() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "Nextcloud", directoryHint: .isDirectory)

        // Captured with nothing at the path, so the disk cannot say what it is
        // and the row falls back to `.file` — the same end state as every entry
        // in a history stored before folders were told apart.
        await store.capture(fileItem(folder))
        #expect(store.items.first?.kind == .file)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await store.capture(fileItem(folder))
        #expect(store.items.count == 1)
        #expect(store.items.first?.kind == .folder)
    }

    @Test("A row already labelled Folder survives a re-copy that cannot look")
    func keepsFolderKindWhenPathIsUnreachable() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appending(path: "Nextcloud", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await store.capture(fileItem(folder))
        #expect(store.items.first?.kind == .folder)

        // Ejected volume, or deleted since the copy. Overwriting the row with
        // the capture rules' `.file` here is the original bug coming back on a
        // row that was already right.
        try FileManager.default.removeItem(at: folder)
        await store.capture(fileItem(folder))
        #expect(store.items.count == 1)
        #expect(store.items.first?.kind == .folder)
    }

    @Test("A folder replaced by a file of the same name is relabelled")
    func downgradesWhenTheDiskSaysSo() async throws {
        let store = try makeStore()
        let directory = try Fixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // No trailing slash, so the very same URL can name a file afterwards
        // and the payload — and therefore the content hash — does not change.
        let path = directory.appending(path: "Nextcloud", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        await store.capture(fileItem(path))
        #expect(store.items.first?.kind == .folder)

        // Folder → file is only wrong when it is a guess. Here the disk looked
        // and answered, so the row follows it.
        try FileManager.default.removeItem(at: path)
        try Data("now a document".utf8).write(to: path)
        await store.capture(fileItem(path))
        #expect(store.items.first?.kind == .file)
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
