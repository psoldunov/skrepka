import CGtk4

/// The General pane's widgets: the shortcut, pasting, and launch at login.
///
/// Decides nothing: ``render(_:)`` copies a ``GeneralPaneState`` onto the
/// widgets, and the switch reports through ``onLaunchAtLogin``.
final class GeneralPane {
    var onLaunchAtLogin: ((Bool) -> Void)? {
        get { launch.onToggle }
        set { launch.onToggle = newValue }
    }
    var onPasteAutomatically: ((Bool) -> Void)? {
        get { paste.onToggle }
        set { paste.onToggle = newValue }
    }

    let page: SettingsPage
    private let shortcutRow: SettingsRow
    private let keys: KeycapRow
    private let paste: SettingsSwitchRow
    private let launch: SettingsSwitchRow

    init() throws {
        let page = try SettingsPage(title: SettingsSection.general.title)
        let shortcut = try SettingsCard(title: "Shortcut", footer: GeneralPaneState.shortcutFooter)
        let shortcutRow = try SettingsRow(
            title: "Open Skrepka",
            subtitle: nil,
            icon: ["input-keyboard-symbolic", "preferences-desktop-keyboard-shortcuts-symbolic"])
        let keys = try KeycapRow()
        shortcutRow.addTrailing(keys.widget)
        shortcut.add(shortcutRow.widget)

        let pasting = try SettingsCard(title: "Pasting", footer: GeneralPaneState.pastingFooter)
        let paste = try SettingsSwitchRow(
            title: "Paste automatically",
            icon: ["edit-paste-symbolic", "edit-copy-symbolic"])
        pasting.add(paste.row.widget)

        let startup = try SettingsCard(title: "Startup")
        let launch = try SettingsSwitchRow(
            title: "Launch at login", icon: ["system-shutdown-symbolic", "system-run-symbolic"])
        startup.add(launch.row.widget)

        for card in [shortcut, pasting, startup] {
            page.append(card.widget)
        }
        self.page = page
        self.shortcutRow = shortcutRow
        self.keys = keys
        self.paste = paste
        self.launch = launch
    }

    func render(_ state: GeneralPaneState) {
        keys.render(keys: state.shortcutKeys, fallback: state.shortcutValue)
        shortcutRow.setSubtitle(state.shortcutSubtitle)
        paste.render(
            isOn: state.pasteAutomatically,
            isEnabled: state.isPasteEditable,
            subtitle: state.pasteSubtitle
        )
        launch.render(isOn: state.launchAtLogin, isEnabled: true, subtitle: state.launchSubtitle)
    }
}
