import AppKit

/// The modal alerts Clippy puts in front of the user.
///
/// Gathered here so the wording lives together and the coordinator is left
/// deciding *whether* to ask rather than how to phrase it. Every one activates
/// first: Clippy is LSUIElement, so an alert from a background accessory app
/// can otherwise open behind whatever the user was doing.
@MainActor
enum UserAlert {
    /// Explains why an entry was copied rather than pasted, and offers the one
    /// action that fixes it.
    ///
    /// - Returns: true when the user asked to open Accessibility settings.
    static func confirmOpeningAccessibilitySettings(reason: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Copied, but not pasted"
        alert.informativeText = reason
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        return run(alert)
    }

    /// - Returns: true when the user confirmed the clear.
    static func confirmClearingHistory() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned entries are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        return run(alert)
    }

    private static func run(_ alert: NSAlert) -> Bool {
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
