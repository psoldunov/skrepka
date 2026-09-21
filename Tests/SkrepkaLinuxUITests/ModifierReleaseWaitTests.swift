import Testing

@testable import SkrepkaLinuxUI

@Suite("Automatic paste modifier release")
struct ModifierReleaseWaitTests {
    @Test("device state change completes the wait without a key event")
    func deviceStateChange() {
        var modifiers: PickerModifiers = [.alt]
        var didRun = false
        var poll: (() -> Void)?
        let wait = ModifierReleaseWait(
            modifiers: { modifiers },
            schedulePoll: {
                poll = $0
                return {}
            },
            scheduleDeadline: { _ in {} })

        wait.perform { didRun = true }
        #expect(!didRun)

        modifiers = []
        poll?()
        #expect(didRun)
    }

    @Test("a fresh device state avoids delay after a stale shortcut event")
    func freshState() {
        var modifiers: PickerModifiers = [.alt]
        var didRun = false
        let wait = ModifierReleaseWait(
            modifiers: { modifiers },
            scheduleDeadline: { _ in { Issue.record("unexpected deadline cancellation") } })

        modifiers = []
        wait.perform { didRun = true }

        #expect(didRun)
        #expect(!wait.isWaiting)
    }

    @Test("the deadline proceeds while a modifier remains held")
    func deadline() {
        var deadline: (() -> Void)?
        var didRun = false
        let wait = ModifierReleaseWait(
            modifiers: { [.control] },
            scheduleDeadline: {
                deadline = $0
                return {}
            })

        wait.perform { didRun = true }
        deadline?()

        #expect(didRun)
        #expect(!wait.isWaiting)
    }

    @Test("user dismissal cancels a pending hide and paste")
    func dismissalCancelsPaste() {
        var modifiers: PickerModifiers = [.alt]
        var deadline: (() -> Void)?
        var events: [String] = []
        let wait = ModifierReleaseWait(
            modifiers: { modifiers },
            scheduleDeadline: {
                deadline = $0
                return {}
            })
        let paster = FakeModifierPaster { events.append("paste") }

        PickerPasteAction.complete(
            isAutomatic: true,
            paster: paster,
            afterModifiersReleased: wait.perform,
            hide: { events.append("hide") })
        wait.cancel()
        modifiers = []
        wait.modifierStateChanged()
        deadline?()

        #expect(events.isEmpty)
    }
}

private final class FakeModifierPaster: PasteHandling {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func paste() { action() }
}
