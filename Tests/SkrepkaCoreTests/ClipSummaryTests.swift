import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Clip summary")
struct ClipSummaryTests {
    private func summary(
        kind: ClipKind,
        text: String = "",
        imageSize: ClipItem.ImageSize? = nil,
        byteCount: Int? = nil,
        fileCount: Int = 0,
        hasThumbnail: Bool = false,
        hasStackIcons: Bool = false
    ) -> ClipSummary {
        ClipSummary(
            id: UUID(),
            kind: kind,
            text: text,
            sourceBundleID: nil,
            createdAt: Date(),
            isPinned: false,
            isConcealed: false,
            imageSize: imageSize,
            byteCount: byteCount,
            fileCount: fileCount,
            hasThumbnail: hasThumbnail,
            hasStackIcons: hasStackIcons
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
        let shot = summary(kind: .file, text: "shot.png", hasThumbnail: true)
        #expect(shot.isPicture)
    }

    @Test("A copied document is not a picture")
    func documentIsNotPicture() {
        #expect(!summary(kind: .file, text: "notes.txt").isPicture)
    }

    @Test("A picture on disk is a picture even before anything decoded it")
    func imageFileKindIsPicture() {
        #expect(summary(kind: .imageFile, text: "shot.png").isPicture)
    }

    // MARK: - What the row calls it

    @Test("One picture on disk is labelled Image, not File")
    func singleImageFileIsLabelledImage() {
        // What the user asked for: a copied screenshot arrives as a file URL,
        // and the row said "File" while showing the picture.
        #expect(summary(kind: .imageFile, text: "shot.png", fileCount: 1).typeLabel == "Image")
    }

    @Test("A selection is labelled by how many files it holds")
    func selectionIsLabelledByCount() {
        let pictures = summary(kind: .imageFile, text: "a.png\nb.png\nc.png", fileCount: 3)
        #expect(pictures.typeLabel == "3 Images")
        #expect(summary(kind: .file, text: "a\nb", fileCount: 2).typeLabel == "2 Files")
        #expect(summary(kind: .folder, text: "a\nb", fileCount: 2).typeLabel == "2 Folders")
    }

    @Test("A file entry counts files, never lines")
    func fileEntriesNeverCountLines() {
        // The bug in the screenshot: a copy of three files read "3 lines",
        // counting the names its own label was made of.
        let files = summary(kind: .imageFile, text: "a.png\nb.png\nc.png", fileCount: 3)
        #expect(files.lineCountText == nil)
        #expect(summary(kind: .text, text: "one\ntwo\nthree").lineCountText == "3 lines")
        #expect(summary(kind: .text, text: "one line").lineCountText == nil)
    }

    @Test("Several file names read as a list, not as one run-on name")
    func selectionPreviewsAsAList() {
        let files = summary(kind: .imageFile, text: "a.png\nb.png\nc.png", fileCount: 3)
        #expect(files.previewText == "a.png, b.png, c.png")
        #expect(summary(kind: .text, text: "one\ntwo").previewText == "one two")
    }

    @Test("Dimensions describe one picture only")
    func dimensionsAreHiddenForSelections() {
        // A selection is previewed by its first file, so labelling the row
        // 1402 × 578 describes the other two as well, and wrongly.
        let size = ClipItem.ImageSize(width: 1402, height: 578)
        #expect(summary(kind: .imageFile, imageSize: size, fileCount: 1).imageSizeText == "1402 × 578")
        #expect(summary(kind: .imageFile, imageSize: size, fileCount: 3).imageSizeText == nil)
    }

    @Test("Text is never a picture")
    func textIsNotPicture() {
        #expect(!summary(kind: .text, text: "hello").isPicture)
        #expect(!summary(kind: .richText, text: "hello").isPicture)
        #expect(!summary(kind: .link, text: "https://example.com").isPicture)
    }

    // MARK: - Size

    /// Pinned, because the assertions below are about units and separators and
    /// `ByteCountFormatStyle` renders those in the user's language: the same
    /// number is `1.5 MB` in en_US, `1,5 MB` in de_DE and `1,5 Mo` in fr_FR.
    /// Left to the machine's locale these tests pass in Cupertino and fail in
    /// Zurich.
    private static let english = Locale(identifier: "en_US")

    @Test("A measured size renders in the decimal units Finder uses")
    func sizeUsesDecimalUnits() {
        // 1.5 MB rather than 1.43 MB: the `.file` style counts a kilobyte as
        // 1000 bytes, so a row and Get Info agree about the same file.
        let row = summary(kind: .file, text: "clip.mov", byteCount: 1_500_000)
        #expect(row.sizeText(locale: Self.english) == "1.5 MB")
    }

    @Test("An empty file says so rather than spelling out zero")
    func emptySizeIsNotSpelledOut() {
        // The formatter's default for zero is "Zero kB", which reads as an
        // error rather than as an empty file.
        let row = summary(kind: .file, text: "empty.txt", byteCount: 0)
        #expect(row.sizeText(locale: Self.english) == "0 bytes")
    }

    @Test("A size is rendered in the reader's language, not in English")
    func sizeFollowsTheLocale() {
        // The picker asks for no locale and gets the user's, so the row agrees
        // with the Finder window beside it on a Mac set to anything.
        //
        // Asserted piecewise rather than against `"1,5 Mo"`: French separates
        // the number from the unit with U+202F, a narrow no-break space, and a
        // test that depends on an invisible character in its own source is a
        // test one careless editor away from a mystery.
        let french = summary(kind: .file, text: "clip.mov", byteCount: 1_500_000)
            .sizeText(locale: Locale(identifier: "fr_FR"))
        #expect(french?.hasPrefix("1,5") == true)
        #expect(french?.hasSuffix("Mo") == true)
    }

    @Test("An unmeasured entry shows no size at all")
    func unmeasuredHasNoSizeText() {
        #expect(summary(kind: .file, text: "notes.txt").sizeText() == nil)
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
            hasThumbnail: false
        )
        #expect(concealed.sizeText() == nil)
    }
}
