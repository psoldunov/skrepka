import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// When the picker asks the daemon for a row's picture again, and when it does
/// not.
struct PreviewRequestsTests {
    @Test("a picture is asked for once, however often the list redraws")
    func askedOnce() {
        let requests = PreviewRequests()
        #expect(requests.needsAsking("a"))
        let asked = requests.asking("a")
        #expect(!asked.needsAsking("a"))
        #expect(asked.needsAsking("b"))
    }

    @Test("an answer with no picture is asked for again when the picker next opens, and not before")
    func unansweredIsRetriedOnReopen() {
        let answered = PreviewRequests().asking("gone").answered("gone", withPicture: false)
        #expect(!answered.needsAsking("gone"))

        let reopened = answered.reopened()
        #expect(reopened.needsAsking("gone"))

        // Asked again and answered again without one: the next opening retries
        // it once more, rather than the first retry being the last.
        let again = reopened.asking("gone").answered("gone", withPicture: false).reopened()
        #expect(again.needsAsking("gone"))
    }

    @Test("a picture that arrived, decoded or not, is not asked for again on reopening")
    func answeredWithBytesStaysAnswered() {
        let reopened = PreviewRequests().asking("webp").answered("webp", withPicture: true).reopened()
        #expect(!reopened.needsAsking("webp"))
    }

    @Test("reopening forgets only what went unanswered")
    func reopeningIsSelective() {
        let requests = PreviewRequests()
            .asking("shown").asking("gone").answered("gone", withPicture: false)
            .reopened()
        #expect(!requests.needsAsking("shown"))
        #expect(requests.needsAsking("gone"))
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
