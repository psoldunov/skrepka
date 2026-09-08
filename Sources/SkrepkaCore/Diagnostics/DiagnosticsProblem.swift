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
    /// The Wayland session offers no protocol a background client can watch the
    /// clipboard through, and there is no X11 server to fall back to.
    ///
    /// Linux only, and not a permission the user can grant: it is a property of
    /// the compositor. Weston, Cage and Muffin are here, and so is gamescope,
    /// which is why Skrepka on a Steam Deck means Desktop Mode.
    case clipboardSessionUnsupported
    /// GNOME, where Mutter implements no data-control protocol at all.
    ///
    /// A supported configuration with a known remedy rather than a failure —
    /// verified by grepping Mutter's `src/meson.build`, which enumerates its
    /// Wayland protocols and contains no occurrence of `data-control`. The
    /// remedy is the Shell extension, which is why this is its own case rather
    /// than a shade of ``clipboardSessionUnsupported``.
    case clipboardNeedsShellExtension

    /// The one problem worth putting in front of the user, or nil when there is
    /// none.
    ///
    /// Ranked, because showing three warnings at once tells the user nothing
    /// about which to fix first. Storage failing loses everything; capture
    /// being impossible or blocked loses everything new; paste-back is a
    /// convenience.
    /// Both permissions arrive as their own status type rather than as the raw
    /// booleans behind them, so the rule for "is this one a problem" lives in
    /// ``ClipboardStatus`` and ``PasteBackStatus`` and is not restated here.
    ///
    /// - Parameter session: what the Linux clipboard session can do, or nil on
    ///   a platform where the question does not arise. It outranks
    ///   ``clipboardAccessDenied`` because it is the more specific answer to
    ///   the same question — a session with no protocol to watch will also look
    ///   like a run of unreadable reads, and telling the user to grant a
    ///   permission that does not exist on their system is worse than saying
    ///   nothing.
    public static func ranked(
        storage: DiagnosticsSnapshot.Storage,
        clipboardStatus: ClipboardStatus,
        pasteBack: PasteBackStatus,
        session: SessionProblem? = nil
    ) -> DiagnosticsProblem? {
        if case .inMemory = storage { return .storageUnavailable }
        if let session { return session.problem }
        if clipboardStatus == .blocked { return .clipboardAccessDenied }
        if !pasteBack.isSettled { return .accessibilityMissing }
        return nil
    }

    /// A clipboard session that cannot capture, in the two shapes it comes in.
    ///
    /// Deliberately not "every finding about the session": a session running on
    /// the deprecated `wlr-data-control` protocol captures perfectly well, and
    /// putting that in front of a user would be telling them to act on
    /// something that is working. That finding is carried by
    /// `LinuxCaptureProblem` and shown in the pasted diagnostics report
    /// instead.
    public enum SessionProblem: Sendable, Hashable, CaseIterable {
        case noDataControlProtocol
        case gnomeWithoutShellExtension

        /// The user-facing problem this session state amounts to.
        ///
        /// Public because the Linux platform target renders it into the
        /// diagnostics report, and reaching it through `ranked` would mean
        /// assembling a whole snapshot to ask one question.
        public var problem: DiagnosticsProblem {
            switch self {
            case .noDataControlProtocol: .clipboardSessionUnsupported
            case .gnomeWithoutShellExtension: .clipboardNeedsShellExtension
            }
        }
    }

    public var summary: String {
        switch self {
        case .storageUnavailable:
            "Skrepka could not open its history database, so nothing is being saved."
        case .clipboardAccessDenied:
            "Skrepka is not allowed to read the clipboard, so nothing is being recorded."
        case .accessibilityMissing:
            "Accessibility permission is not granted, so Skrepka can only copy."
        case .clipboardSessionUnsupported:
            """
            This desktop session offers no way for a background app to watch the clipboard, \
            so nothing is being recorded.
            """
        case .clipboardNeedsShellExtension:
            """
            GNOME does not let a background app watch the clipboard, so nothing is being \
            recorded until the Skrepka Shell extension is installed.
            """
        }
    }

    /// A few words naming the problem: the menu bar row and its tooltip, and
    /// the picker's empty state.
    public var headline: String {
        switch self {
        case .storageUnavailable: "History is not being saved"
        case .clipboardAccessDenied: "Skrepka can't read the clipboard"
        case .accessibilityMissing: "Paste-back needs Accessibility"
        case .clipboardSessionUnsupported: "This session can't be watched"
        case .clipboardNeedsShellExtension: "GNOME needs the Skrepka extension"
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
        case .clipboardSessionUnsupported:
            """
            Log in to a session that supports clipboard managers — most Wayland compositors \
            and any X11 session do — or run Skrepka under X11.
            """
        case .clipboardNeedsShellExtension:
            """
            Install the Skrepka GNOME Shell extension, or log in to the X11 session \
            from the login screen.
            """
        }
    }
}
