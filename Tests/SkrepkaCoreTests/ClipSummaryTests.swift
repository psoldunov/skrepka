import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Clip summary")
struct ClipSummaryTests {
    private func summary(
        kind: ClipKind,
        text: String = "",
        byteCount: Int? = nil,
        thumbnail: Data? = nil
    ) -> ClipSummary {
        ClipSummary(
            id: UUID(),
            kind: kind,
            text: text,
            sourceBundleID: nil,
            createdAt: Date(),
            isPinned: false,
            isConcealed: false,
            imageSize: nil,
            byteCount: byteCount,
            thumbnail: thumbnail
        )
    }

    @Test("Image data is a picture")
    func imageDataIsPicture() {
        #expect(summary(kind: .image).isPicture)
    }

    @Test("An image copied as a file is a picture, though its kind says file")
    func imageFileIsPicture() {
        // The case the Settings Images tile used to miss: `public.file-url`
        // outranks `public.png`, so a screenshot copied out of Finder is `.file`
        // and counting by kind alone reported zero.
        let shot = summary(kind: .file, text: "shot.png", thumbnail: Data([0x89, 0x50]))
        #expect(shot.isPicture)
    }

    @Test("A copied document is not a picture")
    func documentIsNotPicture() {
        #expect(!summary(kind: .file, text: "notes.txt").isPicture)
    }

    @Test("Text is never a picture")
    func textIsNotPicture() {
        #expect(!summary(kind: .text, text: "hello").isPicture)
        #expect(!summary(kind: .richText, text: "hello").isPicture)
        #expect(!summary(kind: .link, text: "https://example.com").isPicture)
    }

    // MARK: - Size

    @Test("A measured size renders in the decimal units Finder uses")
    func sizeUsesDecimalUnits() {
        // 1.5 MB rather than 1.43 MB: the `.file` style counts a kilobyte as
        // 1000 bytes, so a row and Get Info agree about the same file.
        #expect(summary(kind: .file, text: "clip.mov", byteCount: 1_500_000).sizeText == "1.5 MB")
    }

    @Test("An empty file says so rather than spelling out zero")
    func emptySizeIsNotSpelledOut() {
        // The formatter's default for zero is "Zero kB", which reads as an
        // error rather than as an empty file.
        #expect(summary(kind: .file, text: "empty.txt", byteCount: 0).sizeText == "0 bytes")
    }

    @Test("An unmeasured entry shows no size at all")
    func unmeasuredHasNoSizeText() {
        #expect(summary(kind: .file, text: "notes.txt").sizeText == nil)
    }

    @Test("A concealed entry gives up no size")
    func concealedHidesSize() {
        let concealed = ClipSummary(
            id: UUID(),
            kind: .image,
            text: "",
            sourceBundleID: nil,
            createdAt: Date(),
            isPinned: false,
            isConcealed: true,
            imageSize: nil,
            byteCount: 4096,
            thumbnail: nil
        )
        #expect(concealed.sizeText == nil)
    }
}
