import AppKit
import ClippyCore
import KeyboardShortcuts

/// Adapts a `KeyboardShortcuts.Shortcut` to ``ShortcutSymbols``.
///
/// Deliberately not `Shortcut.description`: that reaches `"space_key".localized`
/// and so `Bundle.module`, which traps on any machine without this
/// repository's `.build` directory — the crash that took Settings down.
enum ShortcutFormatter {
    static func string(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        ShortcutSymbols.string(
            carbonKeyCode: shortcut.carbonKeyCode,
            modifiers: shortcut.modifiers,
            // Resolved through the current keyboard layout by the library, and
            // free of resources — unlike `description`, which wraps it.
            character: shortcut.nsMenuItemKeyEquivalent
        )
    }
}
