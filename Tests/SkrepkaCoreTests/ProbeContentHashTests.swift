import Foundation
import SkrepkaProbe
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// The probe's content hash against the real one.
///
/// `SkrepkaProbe` cannot see `SkrepkaCore` — that target does not build on
/// Linux — so it computes a text clipping's `contentHash` itself. If the two
/// ever disagree, a Mac and the probe hold two rows for one clipping, every
/// merge assertion in the runbook silently tests nothing, and the failure looks
/// like a protocol bug rather than a duplicated constant.
///
/// The one test in this repository that links both, which is the same reason
/// `SyncLimitsTests` exists.
@Suite("Probe content hash")
struct ProbeContentHashTests {
    @Test(
        "The probe reproduces ClipItem's digest for a text clipping",
        arguments: ["", "hello", "a longer clipping, with punctuation — and a dash", "日本語"]
    )
    func matchesClipItem(text: String) {
        let item = ClipItem(
            kind: .text,
            text: text,
            payload: ClipPayload(representations: [PasteboardType.string: Data(text.utf8)])
        )
        #expect(ProbeContentHash.text(text) == item.contentHash)
    }
}
