import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Clip item")
struct ClipItemTests {
    private func payload(_ text: String) -> ClipPayload {
        ClipPayload(representations: [PasteboardType.string: Data(text.utf8)])
    }

    private func files(_ strings: String...) -> [URL] {
        strings.compactMap(URL.init(string:))
    }

    @Test("Identical text hashes identically regardless of when it was copied")
    func hashIsContentOnly() {
        let first = ClipItem(kind: .text, text: "same", payload: payload("same"))
        let second = ClipItem(
            kind: .text,
            text: "same",
            payload: payload("same"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        #expect(first.contentHash == second.contentHash)
        #expect(first.id != second.id)
    }

    @Test("Different text hashes differently")
    func hashDistinguishesContent() {
        let first = ClipItem(kind: .text, text: "a", payload: payload("a"))
        let second = ClipItem(kind: .text, text: "b", payload: payload("b"))
        #expect(first.contentHash != second.contentHash)
    }

    @Test("Images hash their bytes, not their empty text")
    func imageHashUsesBytes() {
        let red = ClipPayload(representations: [PasteboardType.png: Data([1, 2, 3])])
        let blue = ClipPayload(representations: [PasteboardType.png: Data([4, 5, 6])])
        let first = ClipItem(kind: .image, text: "", payload: red)
        let second = ClipItem(kind: .image, text: "", payload: blue)
        #expect(first.contentHash != second.contentHash)
    }

    @Test("PDF-only images hash their bytes, since PDF is a kind of image here")
    func pdfOnlyImageHashUsesBytes() {
        let first = ClipPayload(representations: [PasteboardType.pdf: Data([1, 2, 3])])
        let second = ClipPayload(representations: [PasteboardType.pdf: Data([4, 5, 6])])
        #expect(
            ClipItem(kind: .image, text: "", payload: first).contentHash
                != ClipItem(kind: .image, text: "", payload: second).contentHash
        )
    }

    @Test("An image carrying no ranked representation still hashes what it has")
    func unrankedImageHashUsesEverything() {
        let first = ClipPayload(representations: ["com.example.custom": Data([1])])
        let second = ClipPayload(representations: ["com.example.custom": Data([2])])
        #expect(
            ClipItem(kind: .image, text: "", payload: first).contentHash
                != ClipItem(kind: .image, text: "", payload: second).contentHash
        )
    }

    @Test("Files hash their full URL, not the filename the row happens to show")
    func fileHashUsesFullURL() {
        let first = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a/shot.png".utf8)
        ])
        let second = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/b/shot.png".utf8)
        ])
        // Both entries are labelled "shot.png"; only the payload tells them apart.
        #expect(
            ClipItem(kind: .file, text: "shot.png", payload: first).contentHash
                != ClipItem(kind: .file, text: "shot.png", payload: second).contentHash
        )
    }

    @Test("The same file copied twice still collapses onto one entry")
    func sameFileHashesIdentically() {
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/a/shot.png".utf8)
        ])
        #expect(
            ClipItem(kind: .file, text: "shot.png", payload: payload).contentHash
                == ClipItem(kind: .file, text: "shot.png", payload: payload).contentHash
        )
    }

    @Test("A folder hashes the same as the file entry it used to be recorded as")
    func folderSharesFileHashDomain() {
        // Every folder in a history stored before folders were told apart is
        // recorded as `.file`. Feeding the case into the hash would make the
        // `.folder` capture of that same folder today a second, separate row —
        // and would leave the stale one saying "File" for good.
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/Nextcloud/".utf8)
        ])
        #expect(
            ClipItem(kind: .file, text: "Nextcloud", payload: payload).contentHash
                == ClipItem(kind: .folder, text: "Nextcloud", payload: payload).contentHash
        )
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

    @Test("A file entry knows the file its payload names, even listed as none")
    func fileURLsFallBackToThePayload() {
        let payload = ClipPayload(representations: [
            PasteboardType.fileURL: Data("file:///Users/me/shot.png".utf8)
        ])
        let item = ClipItem(kind: .file, text: "shot.png", payload: payload)
        #expect(item.fileURLs == files("file:///Users/me/shot.png"))
    }

    @Test("Multi-line text previews as one line")
    func previewCollapsesLines() {
        let item = ClipItem(kind: .text, text: "line one\n\n  line two  ", payload: payload("x"))
        #expect(item.previewText == "line one line two")
    }

    @Test("Concealed items never preview their content")
    func concealedPreviewIsMasked() {
        let item = ClipItem(kind: .text, text: "hunter2", payload: payload("x"), isConcealed: true)
        #expect(item.previewText == "••••••••")
    }

    @Test("Pinning produces a new value and preserves identity and hash")
    func pinningIsImmutable() {
        let item = ClipItem(kind: .text, text: "a", payload: payload("a"))
        let pinned = item.withPinned(true)
        #expect(!item.isPinned)
        #expect(pinned.isPinned)
        #expect(pinned.id == item.id)
        #expect(pinned.contentHash == item.contentHash)
    }

    @Test("Payload byte count sums every representation")
    func byteCountSums() {
        let payload = ClipPayload(representations: [
            PasteboardType.string: Data(count: 10),
            PasteboardType.rtf: Data(count: 25),
        ])
        #expect(payload.byteCount == 35)
    }
}
