import Testing

@testable import SkrepkaLinuxPlatform

/// RFC 6762 §8.1: only a defence heard after the first probe went out counts.
@Suite("mDNS probe window")
struct MDNSProbeWindowTests {
    @Test("a conflict before the first probe is ignored")
    func ignoresEarlyConflicts() {
        #expect(!MDNSProbeWindow.closed.noting(conflict: true).sawConflict)
    }

    @Test("a conflict once probing has begun counts, and stays counted")
    func countsLiveConflicts() {
        let seen = MDNSProbeWindow.opened.noting(conflict: true)
        #expect(seen.sawConflict)
        #expect(seen.noting(conflict: false).sawConflict)
        #expect(!MDNSProbeWindow.opened.noting(conflict: false).sawConflict)
    }
}
