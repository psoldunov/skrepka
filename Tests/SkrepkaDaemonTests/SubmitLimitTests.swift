import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// What ``Daemon/submit(_:)`` does with a submission that is too big, and what
/// it says about one that is merely malformed.
///
/// The size check used to run *after* `decodedRepresentations()`, so any client
/// on the session bus could make the daemon allocate the whole payload before
/// being told no. The check now runs on the encoded length first, and the
/// decoded check stays as the exact bound.
@Suite("Submissions are bounded before they are decoded")
struct SubmitLimitTests {
    static func daemon() throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-submit-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:])
    }

    static let plainText = "text/plain;charset=utf-8"

    @Test("an ordinary submission is recorded")
    func anOrdinarySubmissionIsRecorded() async throws {
        let daemon = try Self.daemon()
        let request = SubmitRequest(
            representations: [Self.plainText: Data("hello".utf8).base64EncodedString()]
        )

        let answer = await daemon.submit(request)

        #expect(answer.ok)
    }

    /// The payload here is over the encoded ceiling **and** not valid base64,
    /// which is what makes this an ordering test rather than a size test.
    ///
    /// Check the size first and the answer is about size. Decode first — the
    /// order this had — and the decode fails, so the same submission is
    /// reported as malformed and the allocation the ceiling exists to prevent
    /// has already been attempted. Two different sentences, and only one of
    /// them tells the user what to change.
    @Test("an oversized submission is refused for its size, before it is decoded")
    func anOversizedSubmissionIsRefusedBeforeDecoding() async throws {
        let daemon = try Self.daemon()
        let payload = String(repeating: "!", count: SubmitRequest.encodedSizeLimit + 4)
        let request = SubmitRequest(representations: [Self.plainText: payload])

        let answer = await daemon.submit(request)

        #expect(answer.ok == false)
        #expect(answer.detail.contains("limit"))
        #expect(answer.detail.contains("base64") == false)
    }

    /// And the other failure keeps its own words, because a client that sent
    /// broken base64 has a different bug from one that sent too much.
    @Test("a malformed submission is refused as malformed")
    func aMalformedSubmissionIsRefusedAsMalformed() async throws {
        let daemon = try Self.daemon()
        let request = SubmitRequest(representations: [Self.plainText: "not base64 !!!"])

        let answer = await daemon.submit(request)

        #expect(answer.ok == false)
        #expect(answer.detail.contains("base64"))
    }
}
