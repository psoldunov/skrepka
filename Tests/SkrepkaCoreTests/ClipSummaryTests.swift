import Foundation
import Testing

@testable import SkrepkaCore

@Suite("Clip summary")
struct ClipSummaryTests {
    private func summary(
        kind: ClipKind,
        text: String = "",
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
}
