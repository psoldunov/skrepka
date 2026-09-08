import SkrepkaCore
import Testing

@testable import SkrepkaLinuxUI

/// The picker's whole keyboard contract, which on Linux is decided in Swift
/// rather than by SwiftUI's `onKeyPress`.
///
/// Worth pinning for a reason the macOS side does not have: there, an
/// unrecognised key falls through to a text field the framework put there. Here
/// the fall-through is a `case` in a `switch`, so a key routed to the wrong arm
/// silently stops reaching the search field and the picker looks like it has
/// stopped taking input.
@Suite("Picker key map")
struct PickerCommandTests {
    private static let pageJump = 5

    /// `keycode: 0` is "no hardware key reported", which no real press carries
    /// — the number row starts at 10. Every test that does not name a keycode
    /// is therefore asserting the keysym path alone.
    private static func command(
        _ keysym: UInt32,
        _ modifiers: PickerModifiers = [],
        keycode: UInt32 = 0
    ) -> PickerCommand {
        PickerKeyMap.command(
            keysym: keysym, keycode: keycode, modifiers: modifiers, pageJump: pageJump)
    }

    // MARK: - Navigation

    @Test("Arrows move one row, page keys move a page")
    func navigationKeysMove() {
        #expect(Self.command(Keysym.up) == .moveSelection(by: -1))
        #expect(Self.command(Keysym.down) == .moveSelection(by: 1))
        #expect(Self.command(Keysym.pageUp) == .moveSelection(by: -Self.pageJump))
        #expect(Self.command(Keysym.pageDown) == .moveSelection(by: Self.pageJump))
    }

    @Test("Home and End jump to the ends")
    func homeAndEnd() {
        #expect(Self.command(Keysym.home) == .selectFirst)
        #expect(Self.command(Keysym.end) == .selectLast)
    }

    @Test("Escape dismisses")
    func escapeDismisses() {
        #expect(Self.command(Keysym.escape) == .dismiss)
    }

    @Test("Both Return keys choose, richly")
    func returnChooses() {
        // The keypad's Return is a different keysym and arrives from the same
        // physical gesture. Missing it makes the picker feel broken on exactly
        // one keyboard.
        #expect(Self.command(Keysym.enter) == .choose(.rich))
        #expect(Self.command(Keysym.keypadEnter) == .choose(.rich))
    }

    // MARK: - The search field

    @Test("An ordinary letter belongs to the search field")
    func lettersFallThrough() {
        #expect(Self.command(0x0061) == .type)  // a
        #expect(Self.command(0x0020) == .type)  // space
        #expect(Self.command(Keysym.one) == .type)
    }

    @Test("Shift alone still types")
    func shiftedLettersFallThrough() {
        // Typing a capital letter must not be mistaken for a shortcut.
        #expect(Self.command(0x0041, .shift) == .type)
        #expect(Self.command(Keysym.uppercaseP, .shift) == .type)
    }

    @Test("Control is not the picker's modifier and types instead")
    func controlIsNotClaimed() {
        // Deliberate: Ctrl+1–9 switches tabs and Ctrl+P prints, everywhere on
        // this platform. Claiming them would break the gesture users arrive
        // with — see PickerKeyMap's note.
        #expect(Self.command(Keysym.one, .control) == .type)
        #expect(Self.command(Keysym.lowercaseP, .control) == .type)
    }

    // MARK: - Alt, which is Linux's Command

    @Test("Alt with a digit chooses that row, one-based")
    func altDigitsChooseRows() {
        #expect(Self.command(Keysym.one, .alt) == .chooseRow(index: 0))
        #expect(Self.command(Keysym.nine, .alt) == .chooseRow(index: 8))
    }

    @Test("Alt+0 is not a row")
    func altZeroIsNotARow() {
        // 0x30 sits directly below `one`, so an off-by-one in the range check
        // lands here and chooses row -1. Keycode 19 is the real `0` key, one
        // past the top of the digit row, guarding the same edge on that side.
        #expect(Self.command(0x0030, .alt) == .type)
        #expect(Self.command(0x0030, .alt, keycode: 19) == .type)
    }

    @Test("Alt with a digit chooses that row on a layout that has no digits there")
    func altDigitsSurviveANonQwertyLayout() {
        // The bug this exists for: on AZERTY the number row produces `&é"'(-è_ç`
        // unshifted, so a keysym-only match makes Alt+1–9 a QWERTY-only
        // shortcut and drops the keystroke into the search field everywhere
        // else. The hardware keycode does not move with the layout.
        #expect(Self.command(0x0026, .alt, keycode: 10) == .chooseRow(index: 0))  // Alt+&
        #expect(Self.command(0x00e9, .alt, keycode: 11) == .chooseRow(index: 1))  // Alt+é
        #expect(Self.command(0x00e7, .alt, keycode: 18) == .chooseRow(index: 8))  // Alt+ç
    }

    @Test("The two spellings agree on a layout that has both")
    func qwertyAgreesWithItself() {
        // On QWERTY a real Alt+1 carries the digit keysym *and* keycode 10.
        // They must not disagree, or the row chosen would depend on which
        // branch ran first.
        #expect(Self.command(Keysym.one, .alt, keycode: 10) == .chooseRow(index: 0))
        #expect(Self.command(Keysym.nine, .alt, keycode: 18) == .chooseRow(index: 8))
        // AZERTY reaches the digit through Shift, where both spellings are
        // present too and still have to mean row 1.
        #expect(Self.command(Keysym.one, [.alt, .shift], keycode: 10) == .chooseRow(index: 0))
    }

    @Test("A key outside the digit row is not a row, whatever its keycode")
    func otherKeycodesAreNotRows() {
        // Escape is keycode 9 and Tab is 23 — one either side of the row, and
        // the two an off-by-one in the range would swallow first.
        #expect(Self.command(Keysym.escape, .alt, keycode: 9) == .type)
        #expect(Self.command(0x0071, .alt, keycode: 24) == .type)  // Alt+q
        // Without Alt the keycode is not consulted at all: typing "1" is
        // typing, on every layout.
        #expect(Self.command(Keysym.one, keycode: 10) == .type)
    }

    @Test("Alt+Return chooses richly, and Alt+Shift+Return as plain text")
    func altReturnCarriesStyle() {
        #expect(Self.command(Keysym.enter, .alt) == .choose(.rich))
        #expect(Self.command(Keysym.enter, [.alt, .shift]) == .choose(.plainText))
    }

    @Test("Alt+P pins in either case")
    func altPinsRegardlessOfCase() {
        // With Shift held, X11 reports the shifted keysym, so Alt+Shift+P
        // arrives as 'P'. It should still pin rather than land in the search
        // field as a stray letter.
        #expect(Self.command(Keysym.lowercaseP, .alt) == .togglePin)
        #expect(Self.command(Keysym.uppercaseP, [.alt, .shift]) == .togglePin)
    }

    @Test("An unclaimed Alt combination types rather than vanishing")
    func unclaimedAltCombinationsType() {
        #expect(Self.command(0x0071, .alt) == .type)  // Alt+q
    }

    @Test("Modifier bits the picker does not read are ignored")
    func unreadModifierBitsAreIgnored() {
        // Caps Lock is GDK_LOCK_MASK, bit 1, and arrives in the same word. A
        // picker that treated the whole word as significant would stop
        // responding to Return the moment Caps Lock was on.
        let lock = PickerModifiers(rawValue: 1 << 1)
        #expect(Self.command(Keysym.enter, lock) == .choose(.rich))
        #expect(Self.command(Keysym.escape, lock) == .dismiss)
    }
}
