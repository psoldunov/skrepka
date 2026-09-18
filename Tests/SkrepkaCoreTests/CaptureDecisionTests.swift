import Foundation
import Testing

@testable import SkrepkaCore

/// Which rejections count as the user having copied something — the line a
/// live-push hand-over is ended on.
@Suite("Capture decision")
struct CaptureDecisionTests {
    @Test("Every refusal of real content is a refused copy")
    func refusalsOfContentAreCopies() {
        let refusals: [CaptureDecision] = [
            .rejectedPrivacyMarker,
            .rejectedExcludedApp(bundleID: "com.example.vault"),
            .rejectedTooLarge(byteCount: 1 << 30),
            .rejectedUnreadable,
        ]
        for decision in refusals {
            #expect(decision.isRefusedCopy)
        }
    }

    /// An empty clipboard replaced nothing with anything, and a recorded copy
    /// is not a refusal.
    @Test("An empty clipboard and a capture are not refused copies")
    func emptyAndCapturedAreNot() throws {
        #expect(!CaptureDecision.rejectedEmpty.isRefusedCopy)
        let captured = CaptureRules().decide(
            PasteboardSnapshot(
                representations: [PasteboardType.string: Data("hello".utf8)],
                declaredTypes: [PasteboardType.string]
            )
        )
        try #require(captured.item != nil)
        #expect(!captured.isRefusedCopy)
    }
}
