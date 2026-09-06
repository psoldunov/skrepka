import Foundation
import Testing

@testable import SkrepkaCore

/// Which of an entry's files need a pasteboard item of their own.
///
/// The payload is written as item zero and already carries one of them; getting
/// *which* one wrong is how a paste came to write one file twice and another
/// never.
@Suite("Clip contents")
struct ClipContentsTests {
    private func files(_ strings: String...) -> [URL] {
        strings.compactMap(URL.init(string:))
    }

    private func contents(payload: ClipPayload, files: [URL]) -> ClipContents {
        ClipContents(payload: payload, fileURLs: files)
    }

    @Test("The file the payload carries is excluded exactly once")
    func excludesThePayloadsOwnFile() throws {
        let carried = try #require(URL(string: "file:///Users/me/a.png"))
        let all = files("file:///Users/me/a.png", "file:///Users/me/b.png", "file:///Users/me/c.png")

        let entry = contents(payload: Fixtures.fileURLPayload(carried), files: all)
        #expect(entry.additionalFileURLs == files("file:///Users/me/b.png", "file:///Users/me/c.png"))
    }

    @Test("The payload's file is found wherever it sits in the list")
    func excludesByIdentityNotByPosition() throws {
        // The list is rewritten by every re-copy that de-duplicates onto the row
        // and the payload never is, so the two disagree about which file came
        // first. Dropping the list's first entry is what dropped a real file.
        let carried = try #require(URL(string: "file:///Users/me/a.png"))
        let all = files("file:///Users/me/b.png", "file:///Users/me/a.png", "file:///Users/me/c.png")

        let entry = contents(payload: Fixtures.fileURLPayload(carried), files: all)
        #expect(entry.additionalFileURLs == files("file:///Users/me/b.png", "file:///Users/me/c.png"))
    }

    @Test("A payload carrying no file leaves every file needing an item")
    func keepsEveryFileWhenThePayloadNamesNone() {
        // `public.file-url` holding something that is not a file URL is a kind
        // of copy the capture rules still call `.file`. There is no file on item
        // zero to make room for, so excluding one would simply lose it.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("https://example.com/a.png".utf8)
        ])
        let all = files("file:///Users/me/a.png", "file:///Users/me/b.png")

        #expect(contents(payload: payload, files: all).additionalFileURLs == all)
    }

    @Test("A file listed twice is never given a second pasteboard item")
    func excludesThePayloadsFileWhereverItRepeats() throws {
        // ``ClipItem`` keeps a duplicate out of the list in the first place, so
        // this is about not depending on that: Finder answers the same file
        // listed twice by copying it twice, which is a worse failure than the
        // one being guarded against.
        let carried = try #require(URL(string: "file:///Users/me/a.png"))
        let all = files("file:///Users/me/a.png", "file:///Users/me/b.png", "file:///Users/me/a.png")

        let entry = contents(payload: Fixtures.fileURLPayload(carried), files: all)
        #expect(entry.additionalFileURLs == files("file:///Users/me/b.png"))
    }

    @Test("A row stored before selections were kept needs no extra items")
    func legacyEntryHasNoAdditionalFiles() throws {
        // Its file list is empty and its one file is on the payload, so it
        // pastes exactly as it always did.
        let carried = try #require(URL(string: "file:///Users/me/a.png"))
        #expect(contents(payload: Fixtures.fileURLPayload(carried), files: []).additionalFileURLs.isEmpty)
    }

    @Test("An entry holding only the payload's file needs no extra items")
    func singleFileEntryHasNoAdditionalFiles() throws {
        let carried = try #require(URL(string: "file:///Users/me/a.png"))
        let entry = contents(payload: Fixtures.fileURLPayload(carried), files: [carried])
        #expect(entry.additionalFileURLs.isEmpty)
    }
}
