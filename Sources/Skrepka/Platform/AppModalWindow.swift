import AppKit

/// Keeps an app-modal window above the panels Skrepka floats.
///
/// ``AccessoryPanel`` floats at `.floating` until it is dismissed, and both an
/// `NSAlert`'s window and an `NSOpenPanel` are created at `.normal` — measured
/// against the macOS 26 SDK, where the two levels are 3 and 0. Run as they come,
/// a modal opened from the settings window draws *behind* the window that
/// opened it while still swallowing every event that reaches the app: the user
/// sees a settings window that has stopped responding and no dialog to answer.
/// The exclusion picker in ``PrivacySettingsView`` is the case that has to work,
/// because it is opened from inside a floating panel every time.
///
/// `.modalPanel` is the level AppKit reserves for this and sits at 8, above
/// anything Skrepka floats. Setting it before the session starts is enough:
/// both call paths that reach here — `NSAlert.runModal()` and
/// `NSOpenPanel.runModal()` — were driven against the macOS 26 SDK with the
/// level read from a timer running in `.modalPanel` mode, and each held 8
/// before, during and after the session rather than resetting it.
enum AppModalWindow {
    /// Raises `window` above Skrepka's floating panels, to be called before the
    /// modal session starts.
    ///
    /// Takes an `NSWindow` rather than each concrete type because the two
    /// callers hand over different things: `NSAlert` exposes its window, and
    /// `NSOpenPanel` *is* one.
    static func liftAboveFloatingPanels(_ window: NSWindow) {
        window.level = .modalPanel
    }
}
