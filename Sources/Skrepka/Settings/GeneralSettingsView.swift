import KeyboardShortcuts
import SkrepkaCore
import SwiftUI

/// Shortcut, paste behaviour, launch at login.
struct GeneralSettingsView: View {
    let coordinator: AppCoordinator

    @State private var loginItemError: String?
    @State private var isAccessibilityTrusted = AccessibilityPermission.isTrusted
    /// launchd's answer, not a stored preference — see ``Preferences`` for why
    /// there is no `launchAtLogin` setting to read instead. One snapshot rather
    /// than a `status` poll per property, so the switch and every notice
    /// *derived from it* describe the same instant.
    ///
    /// `loginItemError` is the exception and is not derived from this: it
    /// records what happened at one click and outlives its own cause, which is
    /// why ``refreshLoginItemFromSystem()`` retires it once the status moves.
    ///
    /// Optional and filled by the refresh rather than initialised inline, the
    /// way ``DiagnosticsSettingsView`` holds its snapshot: reading it here would
    /// run a blocking XPC call to `smd` on *every* construction of this view —
    /// once per tab change — and SwiftUI keeps only the first.
    @State private var loginItem: DiagnosticsSnapshot.LoginItemState?

    private var preferences: Preferences { coordinator.preferences }

    /// Whether the notice below the switch has anything to say. Derived rather
    /// than spelled out, so this pane, the welcome card and the menu bar badge
    /// cannot drift apart on what counts as a problem.
    private var pasteBackStatus: PasteBackStatus {
        PasteBackStatus(
            isAccessibilityTrusted: isAccessibilityTrusted,
            pasteAutomatically: preferences.pasteAutomatically
        )
    }

    var body: some View {
        AppIdentityHeader()

        SettingsCard(
            title: "Shortcut",
            footer: "Press this anywhere to open the clipboard picker. It needs no permissions."
        ) {
            SettingsRow(title: "Open Skrepka", symbol: "command") {
                ShortcutRecorderView(name: .showPicker) {
                    coordinator.preferencesChanged()
                }
                .frame(width: 128, height: 24)
            }
        }

        SettingsCard(title: "Pasting", footer: pastingFooter) {
            SettingsRow(
                title: "Paste automatically",
                subtitle: "Send ⌘V to the app you were using.",
                symbol: "arrow.down.doc"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { preferences.pasteAutomatically },
                        set: { setPasteAutomatically($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if !pasteBackStatus.isSettled {
                SettingsNotice(
                    tone: .warning,
                    message: DiagnosticsProblem.accessibilityMissing.summary,
                    actionTitle: SettingsMetrics.widestPermissionLabel,
                    action: AccessibilityPermission.openSettings
                )
            }
        }
        .refreshOnActivation(refreshAccessibility)

        SettingsCard(title: "Startup") {
            SettingsRow(
                title: "Launch at login",
                subtitle: "Skrepka runs in the menu bar with no Dock icon.",
                symbol: "power"
            ) {
                Toggle(
                    "",
                    isOn: Binding(
                        // Nil only until the first refresh lands; an
                        // unanswered status is not a registration.
                        get: { loginItem?.isRegistered ?? false },
                        set: { setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            if let loginItemError {
                SettingsNotice(tone: .error, message: loginItemError)
            } else if loginItem == .requiresApproval {
                SettingsNotice(
                    tone: .warning,
                    message: "Waiting for your approval in Login Items.",
                    actionTitle: "Open Login Items",
                    action: LoginItem.openLoginItemsSettings
                )
            }
        }
        .refreshOnActivation(refreshLoginItemFromSystem)

        if let startupError = coordinator.startupError {
            SettingsCard(title: "Storage") {
                SettingsNotice(tone: .error, message: startupError)
            }
        }
    }

    private var pastingFooter: String {
        preferences.pasteAutomatically
            ? "Choosing an entry pastes it straight into the app you were using."
            : "Choosing an entry copies it. Paste it yourself with ⌘V — no permission needed."
    }

    private func refreshAccessibility() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
    }

    /// The path taken when a settings-style window comes forward: re-read, and
    /// retire a failure message once the system's answer has actually moved.
    ///
    /// Without the retiring, an error outlives its own cause and keeps
    /// suppressing the notice derived from `loginItem` — including the approval
    /// prompt — so the card can show a failed-to-change error underneath a
    /// switch reading on.
    ///
    /// Conditional on the status changing, because this fires when key comes
    /// back *within* the process too: dismissing the picker hands key straight
    /// back to the settings panel. Clearing unconditionally would delete the
    /// message the user is in the middle of reading, having changed nothing.
    private func refreshLoginItemFromSystem() {
        let previous = loginItem
        refreshLoginItem()
        guard loginItem != previous else { return }
        loginItemError = nil
    }

    /// Re-reads the status and nothing else. Kept separate from
    /// ``refreshLoginItemFromSystem()`` because ``setLaunchAtLogin(_:)`` calls
    /// it immediately after setting `loginItemError`, and retiring the message
    /// there would erase the one thing the user needs to read.
    private func refreshLoginItem() {
        loginItem = LoginItem.state
    }

    private func setPasteAutomatically(_ enabled: Bool) {
        preferences.pasteAutomatically = enabled
        guard enabled else { return }
        AccessibilityPermission.requestIfNeeded()
        refreshAccessibility()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginItemError = LoginItem.setEnabled(enabled)
        // Re-read rather than trust what the user just clicked: registering can
        // fail, and it can succeed into `.requiresApproval` instead of
        // `.enabled`. The system's answer is the only one worth showing.
        refreshLoginItem()
    }
}

/// Name, version and icon at the top of the pane — the small courtesy every
/// Apple settings window opens with.
private struct AppIdentityHeader: View {
    var body: some View {
        HStack(spacing: 13) {
            PaperclipMark()
                .fill(.tint)
                .frame(width: 27, height: 27)
                .frame(width: 46, height: 46)
                .background {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.accentColor.opacity(0.14))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Skrepka")
                    .font(.system(size: 17, weight: .semibold))
                Text(Self.versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            BuiltWithEnsemblrLink()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }
}

/// Credit line in the header's empty trailing half, so it costs no height.
private struct BuiltWithEnsemblrLink: View {
    /// Confirmed against the project's own GitHub `homepage` field and the live
    /// page title, not assumed from the bundle identifier.
    private static let destination = URL(string: "https://www.ensemblr.dev")

    @State private var isHovering = false

    var body: some View {
        if let destination = Self.destination {
            Link(destination: destination) {
                HStack(spacing: 3) {
                    Text("Built with Ensemblr")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help("Open ensemblr.dev")
            .accessibilityLabel("Built with Ensemblr. Opens ensemblr.dev.")
        }
    }
}
