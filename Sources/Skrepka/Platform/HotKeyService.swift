import AppKit
import Foundation
import KeyboardShortcuts

/// The global shortcut that opens the picker.
///
/// KeyboardShortcuts wraps Carbon's `RegisterEventHotKey`, which is present and
/// undeprecated in the macOS 26 SDK and — unlike an event tap or a global
/// `NSEvent` monitor — needs no Accessibility permission and does not leak the
/// keystroke into the frontmost app.
enum HotKeyService {
    static func register(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .showPicker, action: handler)
    }
}

extension KeyboardShortcuts.Name {
    /// Default ⌘⇧V. The user can rebind it in Settings; KeyboardShortcuts owns
    /// the persistence.
    static let showPicker = Self(
        "showPicker",
        initial: .init(.v, modifiers: [.command, .shift])
    )
}
