import Foundation
import SkrepkaIPC
import Testing

/// The bound that runs *before* a submission is decoded.
///
/// `SubmitRequest.sizeLimit` is checked on the decoded bytes, which means the
/// allocation a hostile session-bus client is meant to be refused for has
/// already happened by the time it is refused.
/// ``SubmitRequest/isWithinEncodedLimit`` is the cheap pre-check, measured on
/// the encoded string with no decode at all — which is why the payloads below
/// are runs of `A` rather than anything meaningful. Only their length is read.
///
/// The property that matters most is the last one: a bound that refused a
/// submission the exact check would have accepted would make the daemon reject
/// legitimate 32 MB clips, so the generous side is the safe side.
@Suite("Submission size bound")
struct SubmitRequestLimitTests {
    static func request(_ representations: [String: String]) -> SubmitRequest {
        SubmitRequest(representations: representations)
    }

    @Test("a submission with nothing in it is within the limit")
    func emptyIsWithinTheLimit() {
        // Zero bytes cannot exceed a ceiling, and the daemon's own refusal for
        // an empty submission is a different one — this must not pre-empt it
        // with a size complaint.
        #expect(Self.request([:]).isWithinEncodedLimit)
        #expect(Self.request(["text/plain;charset=utf-8": ""]).isWithinEncodedLimit)
    }

    @Test("an ordinary clip is nowhere near the ceiling")
    func ordinaryPayloadIsWithinTheLimit() {
        let encoded = Data("the quick brown fox".utf8).base64EncodedString()
        #expect(Self.request(["text/plain;charset=utf-8": encoded]).isWithinEncodedLimit)
    }

    @Test("a payload exactly at the encoded ceiling is accepted")
    func atTheCeiling() {
        let payload = String(repeating: "A", count: SubmitRequest.encodedSizeLimit)
        #expect(Self.request(["application/octet-stream": payload]).isWithinEncodedLimit)
    }

    @Test("one byte over the encoded ceiling is refused")
    func overTheCeiling() {
        let payload = String(repeating: "A", count: SubmitRequest.encodedSizeLimit + 1)
        #expect(Self.request(["application/octet-stream": payload]).isWithinEncodedLimit == false)
    }

    @Test("the ceiling is on the whole submission, not on one representation")
    func theCeilingIsAggregate() {
        // Two halves that each fit and together do not. Checking per
        // representation would let a client send as much as it liked by
        // splitting it, which is the allocation this is guarding.
        let half = String(repeating: "A", count: SubmitRequest.encodedSizeLimit / 2 + 1)
        let request = Self.request([
            "text/plain;charset=utf-8": half,
            "text/html": half,
        ])
        #expect(request.isWithinEncodedLimit == false)
    }

    @Test("a payload that decodes to exactly the size limit is not refused")
    func theBoundNeverRefusesWhatTheExactCheckAccepts() throws {
        // The one that pins the ratio rather than restating the constant: real
        // base64 of exactly ``SubmitRequest/sizeLimit`` bytes, which the
        // decoded check accepts, so the pre-check must too. If the four-thirds
        // arithmetic is ever tightened into a wrong bound, this fails and the
        // clip-sized-exactly-32-MB case is caught here rather than in the wild.
        let bytes = Data(count: SubmitRequest.sizeLimit)
        let request = Self.request(["application/octet-stream": bytes.base64EncodedString()])
        #expect(request.isWithinEncodedLimit)
        let decoded = try #require(request.decodedRepresentations())
        #expect(decoded.values.reduce(0) { $0 + $1.count } == SubmitRequest.sizeLimit)
    }
}
