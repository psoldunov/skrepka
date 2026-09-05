import KeyboardShortcuts
import SkrepkaCore
import SwiftUI

/// The one-time introduction.
///
/// Its real job is the two permissions. macOS gates programmatic reads of the
/// general pasteboard, and the alert fires on Skrepka's first read whenever that
/// happens to be. Doing one deliberate read from here puts the alert in front
/// of a window that explains what is asking and why, instead of over whatever
/// app the user was in twenty minutes later. ``PasteBackCard`` does the same for
/// Accessibility, which paste-back needs and which is on by default.
struct WelcomeView: View {
    /// Width only. The height is whatever the content needs — see
    /// ``WelcomeWindowController`` — because a fixed height clipped the footer
    /// buttons the moment a line of copy wrapped, and would do it again at any
    /// larger system text size.
    static let windowWidth: CGFloat = 460

    let coordinator: AppCoordinator
    let onFinish: () -> Void

    /// The System Settings half of the answer. Held in state because it is the
    /// one input this window cannot observe — it changes in another app, so it
    /// is re-read when Skrepka comes forward.
    @State private var access: PasteboardAccess = .notYetAsked
    @State private var didRequestAccess = false

    /// Recomputed on every redraw from `coordinator.captureHealth`, which is
    /// `@Observable` — so a capture landing a poll after the user answers the
    /// alert redraws this window on its own. Reading it through a closure was
    /// what hid it from SwiftUI and left "Done" disabled on a working machine.
    private var clipboardStatus: ClipboardStatus {
        ClipboardStatus(access: access, health: coordinator.captureHealth)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                shortcutCard
                permissionCard
                PasteBackCard(preferences: coordinator.preferences)
            }
            .padding(.horizontal, SettingsMetrics.horizontalPadding)

            footerButtons
        }
        .frame(width: Self.windowWidth)
        .background(SettingsBackdrop().ignoresSafeArea())
        // Only the System Settings policy needs this. The capture side is
        // observed, and ``PasteBackCard`` refreshes its own permission.
        .refreshOnActivation(refreshAccess)
    }

    private var header: some View {
        VStack(spacing: 5) {
            Image(systemName: "list.clipboard.fill")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tint)
            Text("Skrepka is running")
                .font(.system(size: 18, weight: .semibold))
            Text("It lives in the menu bar — there is no Dock icon.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    private var shortcutCard: some View {
        SettingsCard(title: "Shortcut", footer: "Change it in Settings. It needs no permission.") {
            SettingsRow(title: "Open Skrepka", symbol: "command") {
                Text(shortcutDescription)
                    .font(SettingsMetrics.controlFont)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionCard: some View {
        // No section title: the card's own row already says what it is, and a
        // header above it just repeated the point.
        SettingsCard(footer: permissionFooter) {
            SettingsRow(
                title: "Reading the clipboard",
                subtitle: permissionSubtitle,
                symbol: "doc.on.clipboard"
            ) {
                clipboardControl.permissionControl()
            }
        }
    }

    /// A tick when there is nothing to do, a button when there is.
    ///
    /// Asking for a permission the user has already granted trains them to
    /// click past permission requests, so a granted state shows no button at
    /// all.
    @ViewBuilder
    private var clipboardControl: some View {
        switch clipboardStatus {
        case .working:
            StatusIndicator(state: .good)
        case .blocked:
            Button(SettingsMetrics.widestPermissionLabel) {
                SystemSettingsLink.open(SystemSettingsLink.pasteboard)
            }
            .font(SettingsMetrics.controlFont)
        case .unknown:
            Button(didRequestAccess ? "Asked" : "Allow") {
                Task { await requestAccess() }
            }
            .font(SettingsMetrics.controlFont)
            .disabled(didRequestAccess)
        }
    }

    /// Done stays disabled until Skrepka can actually read the clipboard.
    ///
    /// Without the permission the app does nothing at all, so dismissing this
    /// window would leave the user with a menu bar icon that never fills. The
    /// window keeps its close button, so this gates the happy path rather than
    /// trapping anyone who decides against it.
    private var footerButtons: some View {
        HStack {
            Spacer()
            Button("Done", action: onFinish)
                .keyboardShortcut(.defaultAction)
                .font(SettingsMetrics.controlFont)
                .disabled(clipboardStatus != .working)
        }
        .padding(.horizontal, SettingsMetrics.horizontalPadding)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    /// One line each, beside the widest control this row can show — the same
    /// constraint ``PasteBackCard`` writes its subtitles to.
    private var permissionSubtitle: String {
        switch clipboardStatus {
        case .working: "Skrepka is recording what you copy."
        case .blocked: "macOS is blocking Skrepka's reads."
        case .unknown: "macOS asks before an app may read it."
        }
    }

    /// Short enough to stay on one line at this width. A wrapped footer left an
    /// orphan on the second line and pushed the buttons down for no gain.
    ///
    /// The "nothing else to set up" closer belongs to ``PasteBackCard``, the
    /// last card in the window. Claiming it here was how the welcome window came
    /// to contradict the menu bar warning sitting right above it.
    private var permissionFooter: String {
        switch clipboardStatus {
        case .working: "This is all Skrepka needs to build your history."
        case .blocked: DiagnosticsProblem.clipboardAccessDenied.remedy
        case .unknown:
            didRequestAccess
                ? "No alert means macOS has asked before. Check Status for the answer."
                : "Skrepka copies a marker and reads it back. That is what prompts macOS."
        }
    }

    private func refreshAccess() {
        access = coordinator.clipboardAccessPolicy
    }

    private var shortcutDescription: String {
        KeyboardShortcuts.getShortcut(for: .showPicker)
            .map(ShortcutFormatter.string(for:)) ?? "Not set"
    }

    /// Triggers the system's pasteboard access alert deliberately.
    ///
    /// The coordinator owns the round trip because it has to pause capture for
    /// the duration — the probe writes to the general pasteboard, and an
    /// unpaused poller would file that marker as the user's first history
    /// entry. It also records a successful read-back, which is the only proof
    /// available after an "Allow Once": that answer leaves the policy at
    /// `.ask`, so nothing else here would ever report `.working`.
    private func requestAccess() async {
        didRequestAccess = true
        _ = await coordinator.probeClipboardAccess()
        refreshAccess()
    }
}
