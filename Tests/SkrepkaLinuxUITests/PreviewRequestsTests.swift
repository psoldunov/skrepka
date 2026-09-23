import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// When the picker asks the daemon for a row's picture again, and when it does
/// not.
struct PreviewRequestsTests {
    @Test("a picture is asked for once while its answer is outstanding, however often the list redraws")
    func askedOnce() {
        let asked = PreviewRequests().asking("a")
        #expect(!asked.needsAsking("a"))
        #expect(asked.needsAsking("b"))
    }

    @Test("an outstanding request is not sent a second time because the picker reopened")
    func pendingSurvivesReopening() {
        #expect(!PreviewRequests().asking("slow").reopened().needsAsking("slow"))
    }

    @Test("an answer with no picture is asked for again when the picker next opens, and not before")
    func noPictureIsRetriedOnReopen() {
        let answered = PreviewRequests().asking("gone").answered("gone", .noPicture)
        #expect(!answered.needsAsking("gone"))

        let reopened = answered.reopened()
        #expect(reopened.needsAsking("gone"))

        // Answered without one again: the next opening retries it once more,
        // rather than the first retry being the last.
        let again = reopened.asking("gone").answered("gone", .noPicture).reopened()
        #expect(again.needsAsking("gone"))
    }

    @Test("bytes that would not decode are never asked for again")
    func undecodableIsSettled() {
        let settled = PreviewRequests().asking("webp").answered("webp", .undecodable)
        #expect(!settled.needsAsking("webp"))
        #expect(!settled.reopened().needsAsking("webp"))
    }

    @Test("a decoded picture is left to the thumbnail cache, so an evicted one is asked for again")
    func decodedIsForgotten() {
        let decoded = PreviewRequests().asking("shot").answered("shot", .decoded)
        #expect(decoded.needsAsking("shot"))
        #expect(decoded == PreviewRequests())
    }

    @Test("an answer is read from the document and whether its bytes decoded")
    func answerFromDocument() {
        let picture = PreviewDocument.picture(Data([1, 2, 3]), mediaType: "image/png", contentHash: "a")
        let none = PreviewDocument.unavailable("the copied picture is gone", contentHash: "a")
        #expect(PreviewRequests.Answer(picture, decoded: true) == .decoded)
        #expect(PreviewRequests.Answer(picture, decoded: false) == .undecodable)
        #expect(PreviewRequests.Answer(none, decoded: false) == .noPicture)
    }
}

/// The link's half: a preview the daemon never answered is still reported, so
/// the controller can mark it for another try.
struct PickerLinkPreviewFailureTests {
    struct Unreachable: Error {}

    @Test(
        "a preview request that cannot reach the daemon is reported as a preview with no picture",
        .timeLimit(.minutes(1)))
    func unreachableIsReported() async throws {
        let (events, sink) = AsyncStream<PickerEvent>.makeStream()
        let link = PickerLink(connect: { throw Unreachable() }, report: { sink.yield($0) })
        await link.start(retryingAfter: .milliseconds(50))
        link.preview(hash: "abc")

        var reported: PreviewDocument?
        for await event in events {
            guard case .preview(let hash, let document) = event, hash == "abc" else { continue }
            reported = document
            break
        }
        await link.shutdown()

        let document = try #require(reported)
        #expect(document.bytes == nil)
        #expect(document.contentHash == "abc")
    }
}
