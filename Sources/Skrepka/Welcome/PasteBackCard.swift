import SkrepkaCore
import SwiftUI

/// The Accessibility half of first-run setup.
///
/// Skrepka asks for two permissions and used to introduce one. Paste-back is on
/// by default, so a user who finished the welcome window walked straight into a
/// menu bar warning about a permission that window had told them did not exist
/// — "Nothing else to set up" and "Paste-back needs Accessibility", on screen at
/// the same time.
///
/// Unlike the clipboard card this one never blocks Done. Capture is the whole
/// app; paste-back is a convenience, and a user who wants to paste with ⌘V
/// themselves is not misconfigured. The switch is what makes that true rather
/// than merely stated: declining has to *turn the feature off*, because
/// ``DiagnosticsProblem/ranked(storage:clipboardStatus:pasteBack:)`` badges the
/// menu bar for as long as paste-back is on and untrusted. A card that only
/// said "skip it" would have moved the contradiction, not removed it.
struct PasteBackCard: View {
    /// The whole object, not just the flag: this card is the only place in the
    /// welcome window that can retire the permission, and it does that by
    /// writing the preference the badge reads.
    let preferences: Preferences

    @State private var isTrusted = AccessibilityPermission.isTrusted
    @State private var didRequest = false

    private var status: PasteBackStatus {
        PasteBackStatus(
            isAccessibilityTrusted: isTrusted,
            pasteAutomatically: preferences.pasteAutomatically,
            didRequest: didRequest
        )
    }

    var body: some View {
        SettingsCard(footer: footer) {
            SettingsRow(
                title: "Paste automatically",
                subtitle: "Send ⌘V to the app you were using.",
                symbol: "arrow.down.doc"
            ) {
                Toggle("", isOn: pasteAutomatically)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .permissionControl()
            }

            SettingsRowSeparator()

            SettingsRow(
                title: "Accessibility permission",
                subtitle: subtitle,
                symbol: "hand.raised"
            ) {
                control.permissionControl()
            }
        }
        .refreshOnActivation(refresh)
    }

    /// Writes the preference and nothing else.
    ///
    /// Deliberately narrower than `GeneralSettingsView`, which prompts for
    /// Accessibility as the switch goes on: here the Allow button is already on
    /// screen one row down, and a system alert firing out of a switch the user
    /// only meant to flip back is the thing this window exists to avoid.
    private var pasteAutomatically: Binding<Bool> {
        Binding(
            get: { preferences.pasteAutomatically },
            set: { preferences.pasteAutomatically = $0 }
        )
    }

    /// A tick when there is nothing to do, a button when there is, and a muted
    /// dash when the user has turned the feature off — the same vocabulary the
    /// clipboard card above it uses.
    @ViewBuilder
    private var control: some View {
        switch status {
        case .working:
            StatusIndicator(state: .good)
        case .notNeeded:
            StatusIndicator(state: .neutral)
        case .notAsked:
            Button("Allow", action: request)
                .font(SettingsMetrics.controlFont)
        case .awaitingSettings:
            Button(SettingsMetrics.widestPermissionLabel, action: AccessibilityPermission.openSettings)
                .font(SettingsMetrics.controlFont)
        }
    }

    /// One line each, beside the widest control this row can show. A subtitle
    /// that wraps in one state and not another is the layout jumping.
    private var subtitle: String {
        switch status {
        case .working: "Skrepka can send ⌘V for you."
        case .notNeeded: "Not needed while the switch is off."
        case .notAsked, .awaitingSettings: "macOS must trust Skrepka to send ⌘V."
        }
    }

    /// Short enough to stay on one line at ``WelcomeView/windowWidth``, for the
    /// same reason the card above it is.
    private var footer: String {
        switch status {
        case .working: "Nothing else to set up. Copy something and press the shortcut."
        case .notNeeded: "Nothing else to set up. Choosing an entry copies it — press ⌘V yourself."
        case .notAsked: "Turn it off above if you would rather paste with ⌘V yourself."
        case .awaitingSettings: DiagnosticsProblem.accessibilityMissing.remedy
        }
    }

    /// Shows the system prompt, once.
    ///
    /// The result is deliberately ignored: `AXUIElement.h` states that
    /// prompting "occurs asynchronously and does not affect the return value",
    /// so what comes back is the trust state from before the user has answered.
    /// The refresh on activation is what actually catches the answer.
    private func request() {
        didRequest = true
        AccessibilityPermission.requestIfNeeded()
        refresh()
    }

    private func refresh() {
        isTrusted = AccessibilityPermission.isTrusted
    }
}
