import Foundation
import Testing

@testable import ClippyCore

@Suite("History store")
@MainActor
struct HistoryStoreTests {
    private func makeStore(retention: RetentionPolicy = .unlimited) throws -> HistoryStore {
        try HistoryStore(location: nil, retention: retention)
    }

    private func item(
        _ text: String,
        kind: ClipKind = .text,
        source: String? = nil,
        at date: Date = Date()
    ) -> ClipItem {
        ClipItem(
            kind: kind,
            text: text,
            payload: ClipPayload(representations: [PasteboardType.string: Data(text.utf8)]),
            sourceBundleID: source,
            createdAt: date
        )
    }

    @Test("A captured entry shows up in items")
    func capturesEntry() async throws {
        let store = try makeStore()
        #expect(await store.capture(item("hello")))
        #expect(store.items.map(\.text) == ["hello"])
    }

    @Test("Re-copying the same content bumps the entry instead of duplicating it")
    func deduplicates() async throws {
        let store = try makeStore()
        let early = Date(timeIntervalSince1970: 1000)
        let late = Date(timeIntervalSince1970: 2000)
        await store.capture(item("hello", at: early))
        await store.capture(item("world", at: early.addingTimeInterval(1)))
        await store.capture(item("hello", at: late))

        #expect(store.items.count == 2)
        #expect(store.items.first?.text == "hello")
        #expect(store.items.first?.createdAt == late)
    }

    @Test("Payloads survive a round trip through the store")
    func payloadRoundTrip() async throws {
        let store = try makeStore()
        let payload = ClipPayload(representations: [
            PasteboardType.string: Data("plain".utf8),
            PasteboardType.rtf: Data("{\\rtf1 styled}".utf8),
        ])
        let captured = ClipItem(kind: .richText, text: "plain", payload: payload)
        await store.capture(captured)

        let id = try #require(store.items.first?.id)
        let loaded = try #require(store.payload(for: id))
        #expect(loaded == payload)
    }

    @Test("Pinning hoists an entry to the top and survives newer captures")
    func pinningHoists() async throws {
        let store = try makeStore()
        await store.capture(item("old", at: Date(timeIntervalSince1970: 1000)))
        await store.capture(item("new", at: Date(timeIntervalSince1970: 2000)))
        #expect(store.items.first?.text == "new")

        let oldID = try #require(store.items.first(where: { $0.text == "old" })?.id)
        store.togglePin(oldID)
        #expect(store.items.first?.text == "old")
        #expect(store.items.first?.isPinned == true)

        store.togglePin(oldID)
        #expect(store.items.first?.text == "new")
    }

    @Test("Deleting removes just that entry")
    func deletesEntry() async throws {
        let store = try makeStore()
        await store.capture(item("keep"))
        await store.capture(item("drop"))
        let id = try #require(store.items.first(where: { $0.text == "drop" })?.id)
        store.delete(id)
        #expect(store.items.map(\.text) == ["keep"])
    }

    @Test("Clear spares pinned entries by default")
    func clearKeepsPinned() async throws {
        let store = try makeStore()
        await store.capture(item("pinned"))
        let pinnedID = try #require(store.items.first?.id)
        store.togglePin(pinnedID)
        await store.capture(item("transient"))

        store.clear()
        #expect(store.items.map(\.text) == ["pinned"])

        store.clear(keepingPinned: false)
        #expect(store.items.isEmpty)
    }

    @Test("Retention evicts on capture")
    func retentionEvictsOnCapture() async throws {
        let store = try makeStore(retention: RetentionPolicy(maximumItems: 2, maximumAge: nil))
        for index in 0..<5 {
            await store.capture(item("entry \(index)", at: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        #expect(store.items.count == 2)
        #expect(store.items.map(\.text) == ["entry 4", "entry 3"])
    }

    @Test("Tightening retention evicts immediately")
    func retentionAppliesOnChange() async throws {
        let store = try makeStore()
        for index in 0..<4 {
            await store.capture(item("entry \(index)", at: Date(timeIntervalSince1970: 1000 + Double(index))))
        }
        #expect(store.items.count == 4)
        store.retention = RetentionPolicy(maximumItems: 1, maximumAge: nil)
        #expect(store.items.map(\.text) == ["entry 3"])
    }

    @Test("An unknown id yields no payload rather than crashing")
    func unknownPayloadIsNil() throws {
        let store = try makeStore()
        #expect(store.payload(for: UUID()) == nil)
    }

    @Test("Source app is recorded with the entry")
    func recordsSource() async throws {
        let store = try makeStore()
        await store.capture(item("hello", source: "com.apple.Safari"))
        #expect(store.items.first?.sourceBundleID == "com.apple.Safari")
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
