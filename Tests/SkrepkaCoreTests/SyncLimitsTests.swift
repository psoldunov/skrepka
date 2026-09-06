import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

/// The cross-target drift guard, and the only file that links both.
///
/// `SkrepkaSync` cannot import `SkrepkaCore` — that target does not build on
/// Linux until Phase 4, and the sync core has to build there today — so it
/// restates the payload ceiling as a literal. This test is what makes the
/// duplication acceptable rather than merely tolerated: an item too large to
/// capture is too large to receive, and two limits that can drift is one limit
/// and one bug.
@Suite("Sync limits")
struct SyncLimitsTests {
    @Test("The wire payload ceiling is the capture ceiling")
    func matchesCaptureRules() {
        #expect(SyncLimits.maximumPayloadBytes == CaptureRules.defaultMaximumItemBytes)
    }

    /// The number is the initialiser default too, so a `CaptureRules()` built
    /// with no arguments is bounded by the same limit the wire is.
    @Test("A default CaptureRules uses that same ceiling")
    func defaultRulesUseTheSameCeiling() {
        #expect(CaptureRules().maximumItemBytes == SyncLimits.maximumPayloadBytes)
    }

    /// A frame has to be able to carry a maximum-sized payload plus the
    /// metadata wrapped around it, or the largest legal item could never cross.
    @Test("A frame body can hold a maximum payload and its metadata")
    func frameBodyExceedsThePayloadCeiling() {
        #expect(SyncLimits.maximumFrameBodyBytes > SyncLimits.maximumPayloadBytes)
        #expect(SyncLimits.payloadChunkBytes < SyncLimits.maximumPayloadBytes)
        #expect(SyncLimits.previewByteLimit < SyncLimits.payloadChunkBytes)
    }
}
