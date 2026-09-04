import AppKit
import Carbon.HIToolbox
import Testing

@testable import ClippyCore

@Suite("Shortcut symbols")
struct ShortcutSymbolsTests {
    @Test("Modifiers print in Apple's order, not the order they were given")
    func modifiersAreOrdered() {
        #expect(ShortcutSymbols.symbols(for: [.command, .control, .shift, .option]) == "⌃⌥⇧⌘")
        #expect(ShortcutSymbols.symbols(for: []).isEmpty)
    }

    @Test("Clippy's default shortcut renders as ⌘⇧V")
    func rendersTheDefaultShortcut() {
        let text = ShortcutSymbols.string(
            carbonKeyCode: kVK_ANSI_V,
            modifiers: [.command, .shift],
            character: "v"
        )
        #expect(text == "⇧⌘V")
    }

    @Test("Space is spelled out rather than printed as a blank")
    func spaceIsNamed() {
        // The case that crashed the shipped app: KeyboardShortcuts renders this
        // one through Bundle.module, which cannot resolve inside a signed .app.
        let text = ShortcutSymbols.string(
            carbonKeyCode: kVK_Space,
            modifiers: [.command],
            character: " "
        )
        #expect(text == "⌘Space")
    }

    @Test("Named keys ignore the character the layout resolved")
    func namedKeysBeatTheCharacter() {
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_Escape, character: "x") == "⎋")
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_LeftArrow, character: nil) == "←")
    }

    @Test("Function keys are numbered from their key codes")
    func functionKeysAreNumbered() {
        // Carbon's kVK_F* codes neither ascend nor run contiguously, so this
        // cannot be a range — kVK_F1 is 0x7A and kVK_F12 is 0x6F.
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_F1, character: nil) == "F1")
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_F5, character: nil) == "F5")
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_F12, character: nil) == "F12")
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_F20, character: nil) == "F20")
    }

    @Test("An unresolvable key falls back to a placeholder instead of crashing")
    func unknownKeyFallsBack() {
        // A key code with no name, no F-number and no character from the
        // layout. It must render *something* — this is a menu tooltip, not a
        // reason to trap.
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_ANSI_A, character: nil) == "�")
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_ANSI_A, character: "") == "�")
    }

    @Test("Letters are upper-cased the way a menu prints them")
    func lettersAreUpperCased() {
        #expect(ShortcutSymbols.key(carbonKeyCode: kVK_ANSI_A, character: "a") == "A")
    }
}
