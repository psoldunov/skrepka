import Testing

@testable import SkrepkaLinuxUI

/// Alt+Backspace and Alt+Delete delete the selected row; the same keys without
/// Alt belong to the search field.
struct PickerDeleteKeyTests {
    private func command(_ keysym: UInt32, _ modifiers: PickerModifiers) -> PickerCommand {
        PickerKeyMap.command(keysym: keysym, keycode: 0, modifiers: modifiers, pageJump: 5)
    }

    @Test func altBackspaceDeletes() {
        #expect(command(Keysym.backspace, [.alt]) == .deleteSelection)
    }

    @Test func altDeleteDeletes() {
        #expect(command(Keysym.delete, [.alt]) == .deleteSelection)
    }

    @Test func plainBackspaceTypes() {
        #expect(command(Keysym.backspace, []) == .type)
        #expect(command(Keysym.delete, []) == .type)
    }
}
