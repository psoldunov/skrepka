import Foundation

/// A problem the user can act on, with the words to describe it.
///
/// The single owner of this vocabulary. Every surface that names one of these
/// — the menu bar row, the picker's empty state, the settings notices, the
/// pasted report — reads its wording from here, so a rename in System Settings
/// is one edit rather than five.
public enum DiagnosticsProblem: Sendable, Hashable, CaseIterable {
    case storageUnavailable
    case clipboardAccessDenied
    case accessibilityMissing

    /// The one problem worth putting in front of the user, or nil when there is
    /// none.
    ///
    /// Ranked, because showing three warnings at once tells the user nothing
    /// about which to fix first. Storage failing loses everything; capture
    /// being blocked loses everything new; paste-back is a convenience.
    /// Both permissions arrive as their own status type rather than as the raw
    /// booleans behind them, so the rule for "is this one a problem" lives in
    /// ``ClipboardStatus`` and ``PasteBackStatus`` and is not restated here.
    public static func ranked(
        storage: DiagnosticsSnapshot.Storage,
        clipboardStatus: ClipboardStatus,
        pasteBack: PasteBackStatus
    ) -> DiagnosticsProblem? {
        if case .inMemory = storage { return .storageUnavailable }
        if clipboardStatus == .blocked { return .clipboardAccessDenied }
        if !pasteBack.isSettled { return .accessibilityMissing }
        return nil
    }

    public var summary: String {
        switch self {
        case .storageUnavailable:
            "Skrepka could not open its history database, so nothing is being saved."
        case .clipboardAccessDenied:
            "Skrepka is not allowed to read the clipboard, so nothing is being recorded."
        case .accessibilityMissing:
            "Accessibility permission is not granted, so Skrepka can only copy."
        }
    }

    /// A few words naming the problem: the menu bar row and its tooltip, and
    /// the picker's empty state.
    public var headline: String {
        switch self {
        case .storageUnavailable: "History is not being saved"
        case .clipboardAccessDenied: "Skrepka can't read the clipboard"
        case .accessibilityMissing: "Paste-back needs Accessibility"
        }
    }

    /// What to do about it. Names the System Settings pane exactly once, so
    /// the wording cannot drift between the picker, the welcome window and the
    /// Status pane.
    public var remedy: String {
        switch self {
        case .storageUnavailable:
            "Check that Skrepka can write to its Application Support folder, then relaunch it."
        case .clipboardAccessDenied:
            "Set Skrepka to Allow in Privacy & Security ▸ Pasteboard."
        case .accessibilityMissing:
            "Grant Skrepka Accessibility permission to let it paste for you."
        }
    }
}
