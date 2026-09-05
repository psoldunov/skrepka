// AppKit + Carbon only. Not a port: ⌘ ⌥ ⌃ ⇧ and the Carbon key codes are macOS
// notation, so the Linux equivalent in Phase 7 is different content rather than
// the same table compiled twice.
#if canImport(AppKit)

    import AppKit
    import Carbon.HIToolbox
    import Foundation

    /// Renders a keyboard shortcut the way macOS writes one: ⌃⌥⇧⌘V.
    ///
    /// Lives in `SkrepkaCore` and takes a Carbon key code rather than a
    /// `KeyboardShortcuts.Shortcut`, so it is testable without the app target and
    /// without a window server. The app-side adapter is `ShortcutFormatter`.
    ///
    /// Skrepka formats shortcuts itself because the obvious alternative,
    /// `Shortcut.description`, reaches `Bundle.module` for the Space key — and a
    /// SwiftPM resource bundle cannot be resolved from inside a signed `.app`.
    public enum ShortcutSymbols {
        /// - Parameter character: the key's own character, resolved through the
        ///   user's keyboard layout by the caller. Ignored for keys in ``named``,
        ///   whose glyphs are fixed.
        public static func string(
            carbonKeyCode: Int,
            modifiers: NSEvent.ModifierFlags,
            character: String?
        ) -> String {
            symbols(for: modifiers) + key(carbonKeyCode: carbonKeyCode, character: character)
        }

        /// Modifier glyphs in the order Apple prints them: ⌃⌥⇧⌘.
        public static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
            var result = ""
            if modifiers.contains(.control) { result += "⌃" }
            if modifiers.contains(.option) { result += "⌥" }
            if modifiers.contains(.shift) { result += "⇧" }
            if modifiers.contains(.command) { result += "⌘" }
            return result
        }

        /// The key itself.
        ///
        /// Named keys win because their glyphs are fixed whatever the layout.
        /// Everything else uses the character the caller resolved, so a Dvorak or
        /// AZERTY user sees the key they actually pressed rather than the one an
        /// ANSI board would have in that position.
        public static func key(carbonKeyCode: Int, character: String?) -> String {
            if let name = named[carbonKeyCode] {
                return name
            }
            if let number = functionKeys[carbonKeyCode] {
                return "F\(number)"
            }
            guard let character, !character.isEmpty else { return "�" }
            return character.uppercased()
        }

        /// Function keys, by number.
        ///
        /// A table and not a range: Carbon's `kVK_F*` codes are not contiguous and
        /// do not ascend — `kVK_F1` is 0x7A and `kVK_F12` is 0x6F — so
        /// `kVK_F1...kVK_F12` is an invalid range that traps at runtime.
        static let functionKeys: [Int: Int] = [
            kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5,
            kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
            kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
            kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
        ]

        /// Carbon key codes macOS prints as a glyph or a word rather than a
        /// character.
        static let named: [Int: String] = [
            kVK_Space: "Space",
            kVK_Return: "↩",
            kVK_ANSI_KeypadEnter: "⌤",
            kVK_Tab: "⇥",
            kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋",
            kVK_Help: "?⃝",
            kVK_Home: "↖",
            kVK_End: "↘",
            kVK_PageUp: "⇞",
            kVK_PageDown: "⇟",
            kVK_UpArrow: "↑",
            kVK_DownArrow: "↓",
            kVK_LeftArrow: "←",
            kVK_RightArrow: "→",
        ]
    }

#endif
