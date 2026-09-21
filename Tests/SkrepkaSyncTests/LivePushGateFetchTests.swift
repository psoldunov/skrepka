import Foundation
import Testing

@testable import SkrepkaSync

/// Bytes fetched after a push land on the clipboard only if nothing the user
/// would expect to find there instead has happened since.
@Suite("Writing a fetched push")
struct LivePushGateFetchTests {
    private static let pushed = String(repeating: "a", count: 64)
    private static let other = String(repeating: "b", count: 64)
    private static let now = SyncFixtures.epoch

    @Test("Claimed once when nothing happened in between")
    func claimedOnce() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        let answer1 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(answer1)
        let answer2 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer2)
    }

    @Test("A claim notes the write, so the copy it causes is not pushed back")
    func claimNotesTheWrite() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        let answer3 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(answer3)
        let answer4 = gate.admitCopy(Self.pushed, isConcealed: false, at: Self.now)
        #expect(!answer4)
    }

    @Test("A copy made here since the push wins")
    func aLocalCopyWins() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        _ = gate.admitCopy(Self.other, isConcealed: false, at: Self.now)
        let answer5 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer5)
    }

    @Test("A copy the capture rules refused still wins")
    func anUnrecordedCopyWins() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        gate.noteUnrecordedCopy()
        let answer6 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer6)
    }

    @Test("A later push written in the meantime wins")
    func aLaterPushWins() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        gate.noteReceived(Self.other, at: Self.now)
        let answer7 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer7)
    }

    @Test("Only the newest push waiting for bytes may be written")
    func onlyTheNewestWaits() {
        var gate = LivePushGate()
        gate.noteAwaitingBytes(Self.pushed)
        gate.noteAwaitingBytes(Self.other)
        let answer8 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer8)
        let answer9 = gate.claimFetched(Self.other, at: Self.now)
        #expect(answer9)
    }

    @Test("Bytes nobody was waiting for are not written")
    func unrequestedBytes() {
        var gate = LivePushGate()
        let answer10 = gate.claimFetched(Self.pushed, at: Self.now)
        #expect(!answer10)
    }
}
