import Testing

@testable import SkrepkaLinuxUI

@Suite("Automatic paste modifier release")
struct ModifierReleaseWaitTests {
    @Test("continues immediately when no shortcut modifier is held")
    func immediate() {
        var wait = ModifierReleaseWait()
        #expect(wait.begin(with: []) == .proceed)
        #expect(!wait.isWaiting)
    }

    @Test("waits until every shortcut modifier is released")
    func waitsForRelease() {
        var wait = ModifierReleaseWait()
        #expect(wait.begin(with: [.alt, .shift]) == .wait)
        #expect(wait.modifiersChanged(to: [.shift]) == .wait)
        #expect(wait.modifiersChanged(to: []) == .proceed)
        #expect(!wait.isWaiting)
    }

    @Test("the deadline proceeds even while a modifier remains held")
    func deadline() {
        var wait = ModifierReleaseWait()
        #expect(wait.begin(with: [.control]) == .wait)
        #expect(wait.timedOut() == .proceed)
        #expect(!wait.isWaiting)
    }
}
