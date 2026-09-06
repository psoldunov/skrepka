import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// What a store makes of the files an entry holds: how many it says it has, what
/// it calls them, and whether all of them come back for the paste.
///
/// Split from `HistoryStoringTests.swift` for the reason the payload and pairing
/// halves are, and held against both engines for a reason of its own: a
/// multi-file copy is half AppKit and half not. The icons drawn from the list are
/// macOS-only, but the list itself is what any capture on any platform can
/// produce and what the paste needs, so it is written twice — `ClipRecordMapping`
/// and `HistoryStore.backfillFiles(from:into:)` on SwiftData,
/// `SQLiteClipRow`/`SelectionCoding` and `SQLiteHistoryStore.relistFiles(of:onto:)`
/// on SQLite. Two implementations of one behaviour is exactly what drifts, so
/// both run here rather than only where the icons exist.
///
/// Nothing here asserts on the icon stack: that is the one part of a selection
/// the engines are deliberately *not* held identical on, and
/// `HistoryStoreSelectionTests` covers it where it exists.
extension HistoryStoringTests {
    // MARK: - The files an entry holds

    @Test("A copy of several files keeps every one of them", arguments: HistoryStoreEngine.all)
    func aSelectionKeepsEveryFile(engine: HistoryStoreEngine) async throws {
        // Both engines, because the file list is the half of a multi-file copy
        // that is not AppKit: the icons drawn from it are macOS-only, the files
        // themselves are what any capture can produce and what the paste needs.
        // A column added on one engine and forgotten on the other is what this
        // suite exists to catch.
        //
        // Nothing here asserts on the icon stack, and deliberately: macOS draws
        // one through `FileIconStack` while Linux has nothing to draw it with,
        // so it is the one part of a selection the two engines are *not* held
        // identical on. `HistoryStoreSelectionTests` covers it where it exists.
        let store = try await Self.makeStore(engine)
        let files = [
            URL(fileURLWithPath: "/tmp/skrepka-a.txt"),
            URL(fileURLWithPath: "/tmp/skrepka-b.txt"),
        ]
        let item = ClipItem(
            kind: .file,
            text: "skrepka-a.txt\nskrepka-b.txt",
            payload: Fixtures.fileURLPayload(files[0]),
            createdAt: EngineFixtures.at(1),
            fileURLs: files
        )
        #expect(await store.capture(item))

        let summary = try #require(try await store.summaries().first)
        #expect(summary.fileCount == 2)
        #expect(summary.typeLabel == "2 Files")

        let contents = try #require(await store.contents(for: summary.id))
        #expect(contents.fileURLs == files)
        // The payload carries the first file and no more, so the other one has
        // to come back as an item of its own — see `ClipContents`.
        #expect(contents.additionalFileURLs == [files[1]])
    }

    /// A selection as a capture hands it over: named from its files, with the
    /// first of them also in the payload — see `CaptureRules`.
    private func selection(_ urls: [URL], at instant: TimeInterval) -> ClipItem {
        ClipItem(
            kind: .file,
            text: urls.map(\.lastPathComponent).joined(separator: "\n"),
            payload: Fixtures.fileURLPayload(urls[0]),
            createdAt: EngineFixtures.at(instant),
            fileURLs: urls
        )
    }

    @Test(
        "A repeat copy of a selection relists its files",
        arguments: HistoryStoreEngine.all
    )
    func aRepeatCopyRelistsTheSelection(engine: HistoryStoreEngine) async throws {
        // The dedupe branch, which each engine writes for itself:
        // `HistoryStore.backfillFiles(from:into:)` on SwiftData and
        // `SQLiteHistoryStore.relistFiles(of:onto:)` on SQLite. Nothing else in
        // this suite reaches it — the repeat-copy test above copies text, which
        // has no file list, and the selection test above copies once — so
        // without this one the two implementations could drift apart unnoticed,
        // which is the whole failure this suite exists to catch.
        let store = try await Self.makeStore(engine)
        let first = URL(fileURLWithPath: "/tmp/skrepka-a.txt")
        let second = URL(fileURLWithPath: "/tmp/skrepka-b.txt")

        #expect(await store.capture(selection([first, second], at: 1)))
        #expect(await store.capture(selection([second, first], at: 2)))

        // One row: a selection hashes on its whole set, sorted, so which file
        // was clicked first cannot file the same copy twice.
        let summaries = try await store.summaries()
        #expect(summaries.count == 1)
        let summary = try #require(summaries.first)
        #expect(summary.createdAt == EngineFixtures.at(2))
        // Relisted in the second copy's order, and renamed from it in the same
        // breath: a list rewritten under the old name leaves the row naming one
        // set of files and holding another.
        #expect(summary.fileCount == 2)
        #expect(summary.text == "skrepka-b.txt\nskrepka-a.txt")

        let contents = try #require(await store.contents(for: summary.id))
        #expect(contents.fileURLs == [second, first])
        // The payload belongs to the *first* copy and is never rewritten, so it
        // still carries `first` while the list now leads with `second`. Excluding
        // by identity rather than by position is what keeps the paste from
        // writing one file twice and the other never — see `ClipContents`.
        #expect(contents.payload.fileURL == first)
        #expect(contents.additionalFileURLs == [second])
    }

    @Test("A row holding no files reports none rather than an empty list", arguments: HistoryStoreEngine.all)
    func aTextEntryHoldsNoFiles(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        #expect(await store.capture(EngineFixtures.item("bytes", at: EngineFixtures.at(1))))

        let summary = try #require(try await store.summaries().first)
        #expect(summary.fileCount == 0)
        #expect(summary.typeLabel == "Text")
        #expect(try #require(await store.contents(for: summary.id)).fileURLs.isEmpty)
    }

}
