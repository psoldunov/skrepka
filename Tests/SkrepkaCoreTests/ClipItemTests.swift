import Foundation
import Testing

@testable import SkrepkaCore

// The same shim `ClipItem` uses, so the parity tests below reach the same
// SHA-256 the type does rather than a second one.
#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

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

    // MARK: - Cross-platform hash parity

    // `contentHash` is the sync model's identity: two peers decide they hold
    // the same clipping by comparing it. `ClipItem` reaches SHA-256 through
    // CryptoKit on Apple platforms and swift-crypto everywhere else, and
    // swift-crypto's claim to be source-identical is a claim rather than a
    // guarantee this repo can see. So the digest is pinned to literals, which
    // fail on whichever platform drifts instead of silently splitting the
    // history in two.

    @Test("SHA-256 matches the published vectors on whatever library is linked")
    func sha256MatchesKnownAnswers() {
        // FIPS 180-4 sample vectors — independent of anything Skrepka does with
        // the digest, so this fails only if the crypto library itself is wrong.
        #expect(
            ClipItemTests.digest(of: "abc")
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            ClipItemTests.digest(of: "")
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    @Test("A text item's content hash is byte-identical on every platform")
    func textContentHashIsPinned() {
        let item = ClipItem(kind: .text, text: "skrepka", payload: payload("skrepka"))
        // SHA-256 of "text" + "skrepka" — the kind, then the text, which is
        // what ``ClipKind/identityTypes`` being nil means.
        #expect(item.contentHash == "a0627af32ff3103c966d57e22999e928165ea968868bb03ee7458ff7fa3702fd")
    }

    @Test("A payload-hashed item's content hash is byte-identical on every platform")
    func payloadContentHashIsPinned() {
        let item = ClipItem(
            kind: .image,
            text: "",
            payload: ClipPayload(representations: [PasteboardType.png: Data([1, 2, 3])])
        )
        // SHA-256 of "image" + "public.png" + 0x01 0x02 0x03 — the other branch
        // of the hash, where the ranked representation carries identity.
        #expect(item.contentHash == "c2ef824d64dfa99c2d04695f7acc0da4773c85f8e35ac0a88c3777c088141178")
    }

    /// Hex digest of a string, through whichever SHA-256 ``ClipItem`` linked.
    private static func digest(of string: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(string.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
