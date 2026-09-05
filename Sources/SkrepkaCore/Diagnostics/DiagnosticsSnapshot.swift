import Foundation

/// Everything the diagnostics pane shows, gathered into one value.
///
/// A value type so the report is a pure function of it, and so the whole thing
/// can be tested without a pasteboard, a window server or a login item.
public struct DiagnosticsSnapshot: Sendable, Hashable {
    public enum LoginItemState: String, Sendable, Hashable {
        case enabled = "Enabled"
        case requiresApproval = "Waiting for approval"
        case notRegistered = "Not enabled"
        case notFound = "Not found — move Skrepka to Applications"
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

    /// The one problem worth putting in front of the user, or nil when there is
    /// none.
    public var primaryProblem: DiagnosticsProblem? {
        DiagnosticsProblem.ranked(
            storage: storage,
            clipboardStatus: clipboardStatus,
            pasteAutomatically: pasteAutomatically,
            isAccessibilityTrusted: isAccessibilityTrusted
        )
    }
}
