import AppKit
import ApplicationServices
import ClippyCore
import Foundation
import os

/// Accessibility permission, needed only to synthesise the ⌘V that pastes into
/// the frontmost app. Capture and the hotkey work without it.
enum AccessibilityPermission {
    /// Checks without prompting. Passing nil options is what makes it silent.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(nil)
    }

    /// The value of `kAXTrustedCheckOptionPrompt`, spelled literally.
    ///
    /// The imported C global is a `var`, which Swift 6 refuses to read as
    /// concurrency-safe shared mutable state. The literal was confirmed at
    /// runtime against the macOS 26.6.2 HIServices framework rather than
    /// assumed.
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt" as CFString

    /// Checks and shows the system prompt if not yet granted.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        guard !isTrusted else { return true }
        let options = [promptOptionKey: true]
        let granted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !granted {
            ClippyLog.permissions.notice("Accessibility not granted; paste-back is unavailable.")
        }
        return granted
    }

    static func openSettings() {
        SystemSettingsLink.open(SystemSettingsLink.accessibility)
    }
}
