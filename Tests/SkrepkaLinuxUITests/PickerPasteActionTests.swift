import Testing

@testable import SkrepkaLinuxUI

@Suite("Picker copy completion")
struct PickerPasteActionTests {
    @Test("automatic paste hides before it injects")
    func hidesBeforePaste() {
        var events: [String] = []
        let paster = FakePaster { events.append("paste") }

        PickerPasteAction.complete(
            isAutomatic: true,
            paster: paster,
            hide: { events.append("hide") }
        )

        #expect(events == ["hide", "paste"])
    }

    @Test("automatic paste waits for shortcut modifiers before hiding")
    func waitsForModifiers() throws {
        var events: [String] = []
        var release: (() -> Void)?
        let paster = FakePaster { events.append("paste") }

        PickerPasteAction.complete(
            isAutomatic: true,
            paster: paster,
            afterModifiersReleased: { release = $0 },
            hide: { events.append("hide") }
        )

        #expect(events.isEmpty)
        let releaseModifiers = try #require(release)
        releaseModifiers()
        #expect(events == ["hide", "paste"])
    }

    @Test("dismissed picker ignores an automatic copy reply")
    func dismissedPickerDoesNotPaste() {
        #expect(
            !PickerPasteAction.shouldComplete(
                isVisible: false,
                chosenOpening: 1,
                currentOpening: 1))
    }

    @Test("reopened picker ignores an earlier automatic copy reply")
    func reopenedPickerDoesNotPaste() {
        #expect(
            !PickerPasteAction.shouldComplete(
                isVisible: true,
                chosenOpening: 1,
                currentOpening: 2))
    }

    @Test("visible picker completes its own automatic copy reply")
    func visiblePickerPastesForSameOpening() {
        #expect(
            PickerPasteAction.shouldComplete(
                isVisible: true,
                chosenOpening: 2,
                currentOpening: 2))
    }

    @Test("manual mode hides without injecting")
    func manualMode() {
        var events: [String] = []
        let paster = FakePaster { events.append("paste") }

        PickerPasteAction.complete(
            isAutomatic: false,
            paster: paster,
            hide: { events.append("hide") }
        )

        #expect(events == ["hide"])
    }
}

private final class FakePaster: PasteHandling {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func paste() { action() }
}
