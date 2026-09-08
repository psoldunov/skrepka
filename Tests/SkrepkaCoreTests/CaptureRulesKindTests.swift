import Foundation
import Testing

@testable import SkrepkaCore

/// How ``CaptureRules/kind(for:)`` reads a payload's ranking.
///
/// Its own suite rather than more cases in `CaptureRulesTests`, which is
/// already at the body-length limit, and because these are about one question:
/// that the ranking is read from ``PasteboardType`` rather than restated here.
///
/// Against `kind(for:)` rather than `decide(_:)`, because `decide` also drops
/// an entry whose text came back empty — a payload carrying HTML and nothing
/// else is legitimately rejected there, which would hide the classification
/// these are about.
@Suite("Capture rules kind")
struct CaptureRulesKindTests {
    private func payload(_ representations: [String: Data]) -> ClipPayload {
        ClipPayload(representations: representations)
    }

    @Test("Every type in the image list classifies as .image")
    func classifiesEveryImageType() {
        // The list is the definition, so a format added to it must classify
        // here without this file being edited. The bug this guards is silent:
        // a type that hashes and previews as an image but classifies as nil is
        // a picture the user copied and Skrepka never recorded.
        for type in PasteboardType.imageReadOrder {
            #expect(
                CaptureRules.kind(for: payload([type: Data([0x01, 0x02])])) == .image,
                "\(type) should read as .image"
            )
        }
    }

    @Test("Richer types still outrank an image in the same payload")
    func richerTypesOutrankTheImage() {
        // `readOrder` puts rich text, file URLs and bare URLs ahead of every
        // picture format, and reading the image list must not have moved them.
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let richer: [(type: String, kind: ClipKind)] = [
            (PasteboardType.html, .richText),
            (PasteboardType.fileURL, .file),
            (PasteboardType.url, .link),
        ]
        for (type, kind) in richer {
            let both = payload([type: Data("richer".utf8), PasteboardType.png: png])
            #expect(CaptureRules.kind(for: both) == kind, "\(type) should outrank the image")
        }
    }

    @Test("Plain text sits last, so a picture beside it still reads as an image")
    func imageOutranksPlainText() {
        let both = payload([
            PasteboardType.png: Data([0x89, 0x50, 0x4E, 0x47]),
            PasteboardType.string: Data("hi".utf8),
        ])
        #expect(CaptureRules.kind(for: both) == .image)
    }

    @Test("A payload of nothing Skrepka reads classifies as nil")
    func unknownTypesClassifyAsNil() {
        #expect(CaptureRules.kind(for: payload(["com.example.private": Data([0x01])])) == nil)
    }
}
