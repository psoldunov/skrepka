import Foundation
import Testing

@testable import SkrepkaCore

/// How a copy of several files is identified.
///
/// Split from `ClipItemTests` because it is one question with a lot of edges:
/// the identity of a *selection* is the set of files it holds, where the
/// identity of everything else is its payload — and every case below is one way
/// those two rules could be confused for each other.
@Suite("Clip item selections")
struct ClipItemSelectionTests {
    private func files(_ strings: String...) -> [URL] {
        strings.compactMap(URL.init(string:))
    }

    @Test("Two selections sharing a first file are two entries")
    func selectionHashCoversEveryFile() {
        // The payload holds the first file and no more, so without the rest in
        // the hash `[report.pdf, jan.csv]` and `[report.pdf, feb.csv]` are one
        // entry, and the second copy is discarded onto the first.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/report.pdf".utf8)
        ])
        let january = files("file:///Users/me/report.pdf", "file:///Users/me/jan.csv")
        let february = files("file:///Users/me/report.pdf", "file:///Users/me/feb.csv")

        #expect(
            ClipItem(kind: .file, text: "report.pdf", payload: payload, fileURLs: january)
                .contentHash
                != ClipItem(kind: .file, text: "report.pdf", payload: payload, fileURLs: february)
                .contentHash
        )
    }

    @Test("The same files selected in another order are one entry")
    func selectionHashIgnoresOrder() {
        // Which file the pasteboard lists first is which one the user happened
        // to click first — and it is also the one the payload keeps. Hashing
        // either would file the same copy twice.
        let first = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a.png".utf8)
        ])
        let second = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/b.png".utf8)
        ])
        let forwards = files("file:///Users/me/a.png", "file:///Users/me/b.png")

        #expect(
            ClipItem(kind: .file, text: "a.png", payload: first, fileURLs: forwards).contentHash
                == ClipItem(
                    kind: .file,
                    text: "b.png",
                    payload: second,
                    fileURLs: forwards.reversed()
                ).contentHash
        )
    }

    @Test("A selection and its first file on its own are two entries")
    func selectionDoesNotCollapseOntoOneOfItsFiles() {
        // Copying `a.png` and then copying `a.png` with `b.png` beside it are
        // two different copies, and only one of them can paste two files.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a.png".utf8)
        ])
        #expect(
            ClipItem(kind: .file, text: "a.png", payload: payload).contentHash
                != ClipItem(
                    kind: .file,
                    text: "a.png",
                    payload: payload,
                    fileURLs: files("file:///Users/me/a.png", "file:///Users/me/b.png")
                ).contentHash
        )
    }

    @Test("A single file hashes exactly as it did before selections were kept")
    func singleFileHashIsUnchanged() {
        // Every file already in a history was hashed from its payload alone. If
        // listing that same file changed the hash, re-copying it would stop
        // landing on its own row and start duplicating it.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/shot.png".utf8)
        ])
        #expect(
            ClipItem(kind: .file, text: "shot.png", payload: payload).contentHash
                == ClipItem(
                    kind: .file,
                    text: "shot.png",
                    payload: payload,
                    fileURLs: files("file:///Users/me/shot.png")
                ).contentHash
        )
    }

    @Test("The same file listed twice is held, weighed and hashed once")
    func selectionKeepsEachFileOnce() {
        // A copy cannot hold the same file twice. A list that said it did would
        // paste it twice, sum its bytes twice, count it twice on the row, and
        // hash as a selection distinct from the one it really is.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a.png".utf8)
        ])
        let repeated = files("file:///Users/me/a.png", "file:///Users/me/b.png", "file:///Users/me/a.png")
        let once = files("file:///Users/me/a.png", "file:///Users/me/b.png")

        let item = ClipItem(kind: .file, text: "a.png", payload: payload, fileURLs: repeated)
        #expect(item.fileURLs == once)
        #expect(
            item.contentHash
                == ClipItem(kind: .file, text: "a.png", payload: payload, fileURLs: once).contentHash
        )
    }
}
