import AppKit
import SkrepkaCore
import SwiftUI

/// What Skrepka can and cannot do right now, and the one button that fixes
/// each thing.
///
/// This pane exists because both of Skrepka's failure modes are silent: a denied
/// pasteboard and a database that would not open both look exactly like
/// "nobody has copied anything yet".
struct DiagnosticsSettingsView: View {
    let coordinator: AppCoordinator

    /// Re-read whenever the window comes forward, because the answers in it are
    /// changed in System Settings — somewhere Skrepka cannot observe. Capture is
    /// *not* one of them: that comes from `coordinator.captureHealth`, which is
    /// `@Observable` and read live, so a block detected while this pane is open
    /// no longer leaves a green tick on screen.
    @State private var snapshot: DiagnosticsSnapshot?
    @State private var didCopyReport = false

    private var health: CaptureHealth { coordinator.captureHealth }

    /// Its own container rather than three loose cards plus a zero-height
    /// sentinel to hang `onAppear` on: the sentinel was still a child of the
    /// enclosing stack, so it added a full card gap below the Report card on
    /// the tallest pane in a fixed-size window. Spacing matches the parent's,
    /// so the cards sit exactly where they did.
    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            if let snapshot {
                permissionsCard(snapshot)
                storageCard(snapshot)
                reportCard(snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .refreshOnActivation(refresh)
    }

    @ViewBuilder
    private func permissionsCard(_ snapshot: DiagnosticsSnapshot) -> some View {
        SettingsCard(title: "Permissions", footer: pasteboardFooter(snapshot)) {
            clipboardRows(snapshot)
            SettingsRowSeparator()
            accessibilityRows(snapshot)
            SettingsRowSeparator()
            SettingsRow(
                title: "Launch at login",
                subtitle: loginSubtitle(snapshot),
                symbol: "power"
            ) {
                StatusIndicator(state: snapshot.loginItem == .enabled ? .good : .neutral)
            }
        }
    }

    @ViewBuilder
    private func clipboardRows(_ snapshot: DiagnosticsSnapshot) -> some View {
        SettingsRow(
            title: "Read the clipboard",
            subtitle: "Required. Without it Skrepka records nothing at all.",
            symbol: "doc.on.clipboard"
        ) {
            StatusIndicator(state: clipboardState(snapshot))
        }

        if clipboardState(snapshot) != .good {
            SettingsNotice(
                tone: health.isBlocked ? .error : .warning,
                message: clipboardMessage(snapshot),
                actionTitle: "Open Pasteboard Settings",
                action: { SystemSettingsLink.open(SystemSettingsLink.pasteboard) }
            )
        }
    }

    @ViewBuilder
    private func accessibilityRows(_ snapshot: DiagnosticsSnapshot) -> some View {
        SettingsRow(
            title: "Paste into other apps",
            subtitle: "Optional. Without it Skrepka copies and you press ⌘V.",
            symbol: "arrow.down.doc"
        ) {
            StatusIndicator(state: accessibilityState(snapshot))
        }

        if !snapshot.pasteBackStatus.isSettled {
            SettingsNotice(
                tone: .warning,
                message: DiagnosticsProblem.accessibilityMissing.summary,
                actionTitle: "Open Accessibility Settings",
                action: AccessibilityPermission.openSettings
            )
        }
    }

    /// A missing permission is only a warning when something wants it.
    ///
    /// Reading `isAccessibilityTrusted` alone put an orange triangle beside a
    /// feature the user had switched off, with no notice under it and no
    /// problem in the menu bar — a warning about nothing. The muted dash is the
    /// same one ``PasteBackCard`` shows for the same state.
    private func accessibilityState(_ snapshot: DiagnosticsSnapshot) -> StatusIndicator.State {
        switch snapshot.pasteBackStatus {
        case .working: .good
        case .notNeeded: .neutral
        case .notAsked, .awaitingSettings: .warning
        }
    }

    @ViewBuilder
    private func storageCard(_ snapshot: DiagnosticsSnapshot) -> some View {
        SettingsCard(title: "Storage", footer: storageFooter(snapshot)) {
            SettingsRow(title: "History database", symbol: "internaldrive") {
                StatusIndicator(state: isOnDisk(snapshot) ? .good : .bad)
            }
            SettingsRowSeparator()
            SettingsRow(title: "Stored entries", symbol: "tray.full") {
                Text("\(snapshot.itemCount)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if case .inMemory(let reason) = snapshot.storage {
                SettingsNotice(tone: .error, message: reason)
            }
        }
    }

    @ViewBuilder
    private func reportCard(_ snapshot: DiagnosticsSnapshot) -> some View {
        SettingsCard(
            title: "Report",
            footer: "Paste this into a bug report — it carries no clipboard content."
        ) {
            SettingsRow(
                title: "Copy diagnostics",
                subtitle: "Versions, permission states and storage location.",
                symbol: "doc.on.doc"
            ) {
                Button(didCopyReport ? "Copied" : "Copy") {
                    copyReport(snapshot)
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    // MARK: - Wording

    /// The live verdict: the snapshot's policy, weighed against what capture is
    /// doing right now.
    private func clipboardStatus(_ snapshot: DiagnosticsSnapshot) -> ClipboardStatus {
        ClipboardStatus(access: snapshot.pasteboardAccess, health: health)
    }

    private func clipboardState(_ snapshot: DiagnosticsSnapshot) -> StatusIndicator.State {
        switch clipboardStatus(snapshot) {
        case .working: .good
        case .blocked: .bad
        case .unknown: .warning
        }
    }

    /// Three different diagnoses, one shared remedy — the sentence naming the
    /// System Settings pane comes from ``DiagnosticsProblem/remedy`` so it
    /// cannot drift from the picker's empty state or the welcome window.
    private func clipboardMessage(_ snapshot: DiagnosticsSnapshot) -> String {
        let remedy = DiagnosticsProblem.clipboardAccessDenied.remedy
        if health.isBlocked {
            return "The clipboard changed several times but Skrepka was handed no data. \(remedy)"
        }
        if snapshot.pasteboardAccess.isBlocking {
            return "Skrepka is set to Deny, so it cannot record anything. \(remedy)"
        }
        return
            "Skrepka has not read the clipboard yet, so macOS has not been asked for permission. Copy something to find out."
    }

    private func pasteboardFooter(_ snapshot: DiagnosticsSnapshot) -> String {
        "Clipboard access: \(snapshot.pasteboardAccess.summary). Last capture: \(lastCapture)."
    }

    /// Read from ``CaptureHealth`` rather than the snapshot, so a capture that
    /// lands while this pane is open updates it without a re-gather.
    private var lastCapture: String {
        guard let date = health.lastCapturedAt else { return "never" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func loginSubtitle(_ snapshot: DiagnosticsSnapshot) -> String {
        snapshot.loginItem.rawValue
    }

    private func isOnDisk(_ snapshot: DiagnosticsSnapshot) -> Bool {
        if case .onDisk = snapshot.storage { return true }
        return false
    }

    private func storageFooter(_ snapshot: DiagnosticsSnapshot) -> String {
        switch snapshot.storage {
        case .onDisk(let path): path
        case .inMemory: "Nothing is being written to disk; this session will be lost on quit."
        }
    }

    // MARK: - Actions

    private func refresh() {
        snapshot = coordinator.diagnosticsSnapshot
        didCopyReport = false
    }

    private func copyReport(_ snapshot: DiagnosticsSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticsReport.text(for: snapshot), forType: .string)
        didCopyReport = true
    }
}
