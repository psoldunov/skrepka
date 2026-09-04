import AppKit
import ClippyCore
import Foundation

/// Reads the live system answers Clippy's diagnostics are made of.
///
/// Separate from ``AppCoordinator`` because knowing how to interrogate
/// `NSPasteboard`, `SMAppService` and the Accessibility API is a job of its
/// own, and because gathering here keeps every answer in one place when one of
/// them starts lying.
@MainActor
struct DiagnosticsGatherer {
    private let reader = PasteboardReader()

    /// Assembled on demand rather than cached: every input is a live system
    /// answer, and a stale permission state is worse than no diagnostics at
    /// all — it is the thing sending the user to look in the wrong place.
    func snapshot(
        health: CaptureHealth,
        preferences: Preferences,
        storage: DiagnosticsSnapshot.Storage,
        itemCount: Int
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: Self.appVersion,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            pasteboardAccess: reader.accessBehavior(),
            isCaptureBlocked: health.isBlocked,
            lastCapturedAt: health.lastCapturedAt,
            probeSucceeded: health.probeSucceeded,
            isAccessibilityTrusted: AccessibilityPermission.isTrusted,
            pasteAutomatically: preferences.pasteAutomatically,
            loginItem: LoginItem.state,
            storage: storage,
            itemCount: itemCount
        )
    }

    /// Just the ranked problem, for the menu bar badge.
    ///
    /// Separate from ``snapshot(health:preferences:storage:itemCount:)``
    /// because this one runs on every clipboard change. The full gather also
    /// asks `SMAppService` — a synchronous call into `smd` — and reads the
    /// bundle's version keys, none of which the badge looks at.
    func problem(
        health: CaptureHealth,
        preferences: Preferences,
        storage: DiagnosticsSnapshot.Storage
    ) -> DiagnosticsProblem? {
        DiagnosticsProblem.ranked(
            storage: storage,
            clipboardStatus: clipboardStatus(health: health),
            pasteAutomatically: preferences.pasteAutomatically,
            isAccessibilityTrusted: AccessibilityPermission.isTrusted
        )
    }

    /// The live clipboard reading: the system's policy, weighed against what
    /// the capture loop has actually managed to read.
    func clipboardStatus(health: CaptureHealth) -> ClipboardStatus {
        ClipboardStatus(access: accessPolicy, health: health)
    }

    /// The system's current policy for programmatic pasteboard reads.
    ///
    /// Exposed on its own because it is the one clipboard answer a view cannot
    /// observe: it changes in System Settings, so it is re-read when Clippy
    /// comes forward. Everything else about capture lives in ``CaptureHealth``,
    /// which is `@Observable` and read directly.
    var accessPolicy: PasteboardAccess {
        reader.accessBehavior()
    }

    /// Provokes the system's pasteboard access alert and reports whether the
    /// read that follows it actually worked.
    func probeAccess() -> Bool {
        reader.probeAccess()
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
