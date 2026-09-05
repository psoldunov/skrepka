import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Clip item")
struct ClipItemTests {
    private func payload(_ text: String) -> ClipPayload {
        ClipPayload(representations: [PasteboardType.string: Data(text.utf8)])
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
