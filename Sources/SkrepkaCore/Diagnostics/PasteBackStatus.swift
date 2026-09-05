import Foundation

/// Whether Skrepka can paste an entry back into the app the user came from.
///
/// The Accessibility half of setup, and the single owner of the question — the
/// menu bar badge, the welcome card and both settings panes all read it from
/// here rather than each spelling out `pasteAutomatically && !isTrusted`.
///
/// Its states are deliberately not ``ClipboardStatus``'s: capture is
/// load-bearing — without it the app does nothing — whereas paste-back is a
/// convenience the user is allowed to decline, so this carries a state for
/// "not wanted" and none for "blocked".
public enum PasteBackStatus: Sendable, Hashable, CaseIterable {
    /// Accessibility is granted: choosing an entry sends ⌘V.
    case working
    /// Not granted, and the system prompt has not been shown yet.
    case notAsked
    /// Not granted after the prompt, which is as much as Skrepka can know.
    ///
    /// `AXUIElement.h` is explicit that prompting "occurs asynchronously and
    /// does not affect the return value", so asking again cannot tell us any
    /// more than asking the first time did. System Settings is the only place
    /// the answer is actually given, so that is where the user is sent.
    case awaitingSettings
    /// Automatic pasting is off, so the permission is not wanted. Asking for it
    /// anyway would be asking for a capability nothing would use.
    case notNeeded

    /// - Parameter didRequest: Whether the system prompt has been shown this
    ///   launch. Defaults to false, which is the honest answer for every caller
    ///   outside the surface that does the asking: the prompt leaves no trace
    ///   anything else can read, so a badge or a settings pane genuinely does
    ///   not know. It only separates ``notAsked`` from ``awaitingSettings``,
    ///   and both of those are unsettled, so no caller that stops at
    ///   ``isSettled`` is misled by the default.
    public init(
        isAccessibilityTrusted: Bool,
        pasteAutomatically: Bool,
        didRequest: Bool = false
    ) {
        if !pasteAutomatically {
            self = .notNeeded
        } else if isAccessibilityTrusted {
            self = .working
        } else if didRequest {
            self = .awaitingSettings
        } else {
            self = .notAsked
        }
    }

    /// Whether there is nothing left to ask the user for.
    ///
    /// Granted and switched-off are the same answer to every surface that only
    /// exists to nag: ``DiagnosticsProblem/ranked(storage:clipboardStatus:pasteBack:)``
    /// raises ``DiagnosticsProblem/accessibilityMissing`` exactly when this is
    /// false, and the settings notices and the welcome card hide themselves on
    /// it. Turning paste-back off has to count as settled, or declining the
    /// feature would leave a warning up forever.
    public var isSettled: Bool {
        self == .working || self == .notNeeded
    }
}
