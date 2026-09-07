import Foundation

/// Everything the diagnostics pane shows, gathered into one value.
///
/// A value type so the report is a pure function of it, and so the whole thing
/// can be tested without a pasteboard, a window server or a login item.
public struct DiagnosticsSnapshot: Sendable, Hashable {
    public enum LoginItemState: String, Sendable, Hashable, CaseIterable {
        case enabled = "Enabled"
        case requiresApproval = "Waiting for approval"
        case notRegistered = "Not enabled"
        case notFound = "Not found — move Skrepka to Applications"

        /// Whether a registration exists with launchd.
        ///
        /// `.requiresApproval` counts. `SMAppService.h` describes it as a
        /// service that "has been successfully registered, but the user needs
        /// to take action in System Settings" — the registration is real, and a
        /// surface that drew it as absent would read as a failure and invite
        /// the user to ask for it a second time. Saying what the remaining step
        /// is belongs to whatever sits beside the control, not to this.
        ///
        /// `.notFound` is not registered. `SMAppService.h` defines it broadly —
        /// "an error occurred and no such service could be found" — and the
        /// common cause is launchd refusing an app in a temporary location.
        /// Whatever the cause, nothing was recorded.
        public var isRegistered: Bool {
            self == .enabled || self == .requiresApproval
        }
    }

    public enum Storage: Sendable, Hashable {
        case onDisk(path: String)
        /// The database could not be opened, so nothing survives a relaunch.
        case inMemory(reason: String)
    }

    public let appVersion: String
    public let systemVersion: String
    public let pasteboardAccess: PasteboardAccess
    public let isCaptureBlocked: Bool
    public let lastCapturedAt: Date?
    /// Whether the deliberate access probe read back what it wrote. See
    /// ``CaptureHealth/probeSucceeded``.
    public let probeSucceeded: Bool
    public let isAccessibilityTrusted: Bool
    public let pasteAutomatically: Bool
    public let loginItem: LoginItemState
    public let storage: Storage
    public let itemCount: Int

    public init(
        appVersion: String,
        systemVersion: String,
        pasteboardAccess: PasteboardAccess,
        isCaptureBlocked: Bool,
        lastCapturedAt: Date?,
        probeSucceeded: Bool,
        isAccessibilityTrusted: Bool,
        pasteAutomatically: Bool,
        loginItem: LoginItemState,
        storage: Storage,
        itemCount: Int
    ) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.pasteboardAccess = pasteboardAccess
        self.isCaptureBlocked = isCaptureBlocked
        self.lastCapturedAt = lastCapturedAt
        self.probeSucceeded = probeSucceeded
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.pasteAutomatically = pasteAutomatically
        self.loginItem = loginItem
        self.storage = storage
        self.itemCount = itemCount
    }

    /// Whether Skrepka can actually read the clipboard.
    public var clipboardStatus: ClipboardStatus {
        ClipboardStatus(
            access: pasteboardAccess,
            isCaptureBlocked: isCaptureBlocked,
            hasReadSuccessfully: probeSucceeded || lastCapturedAt != nil
        )
    }

    /// Whether Skrepka can paste back, and whether it needs to be able to.
    ///
    /// No `didRequest`: a snapshot is assembled long after any prompt and has
    /// no way to know one happened, so this reports ``PasteBackStatus/notAsked``
    /// where the welcome card would say ``PasteBackStatus/awaitingSettings``.
    /// Nothing reading a snapshot distinguishes them.
    public var pasteBackStatus: PasteBackStatus {
        PasteBackStatus(
            isAccessibilityTrusted: isAccessibilityTrusted,
            pasteAutomatically: pasteAutomatically
        )
    }

    /// The one problem worth putting in front of the user, or nil when there is
    /// none.
    public var primaryProblem: DiagnosticsProblem? {
        DiagnosticsProblem.ranked(
            storage: storage,
            clipboardStatus: clipboardStatus,
            pasteBack: pasteBackStatus
        )
    }
}
