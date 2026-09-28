import CGtk4

/// The General pane's widgets: the shortcut, pasting, the interface size, and
/// launch at login.
///
/// Decides nothing: ``render(_:)`` copies a ``GeneralPaneState`` onto the
/// widgets, and the controls report through the callbacks.
final class GeneralPane {
    var onLaunchAtLogin: ((Bool) -> Void)? {
        get { launch.onToggle }
        set { launch.onToggle = newValue }
    }
    var onPasteAutomatically: ((Bool) -> Void)? {
        get { paste.onToggle }
        set { paste.onToggle = newValue }
    }
    /// The interface size chosen.
    var onInterfaceScale: ((InterfaceScale) -> Void)?

    let page: SettingsPage
    private let shortcutRow: SettingsRow
    private let keys: KeycapRow
    private let paste: SettingsSwitchRow
    private let interfaceScale: SettingsDropDownRow
    private let launch: SettingsSwitchRow
    /// The sizes last drawn, which a choice's index is read against.
    private var drawnScales: [Int] = []

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

        let appearance = try SettingsCard(title: "Appearance")
        let interfaceScale = try SettingsDropDownRow(
            title: "Interface size",
            icon: ["zoom-in-symbolic", "preferences-desktop-display-symbolic"])
        appearance.add(interfaceScale.row.widget)

        let startup = try SettingsCard(title: "Startup")
        let launch = try SettingsSwitchRow(
            title: "Launch at login", icon: ["system-shutdown-symbolic", "system-run-symbolic"])
        startup.add(launch.row.widget)

        for card in [shortcut, pasting, appearance, startup] {
            page.append(card.widget)
        }
        self.page = page
        self.shortcutRow = shortcutRow
        self.keys = keys
        self.paste = paste
        self.interfaceScale = interfaceScale
        self.launch = launch
        interfaceScale.onSelect = { [weak self] index in
            guard let self, drawnScales.indices.contains(index),
                let scale = InterfaceScale(percent: drawnScales[index])
            else { return }
            onInterfaceScale?(scale)
        }
    }

    func render(_ state: GeneralPaneState) {
        keys.render(keys: state.shortcutKeys, fallback: state.shortcutValue)
        shortcutRow.setSubtitle(state.shortcutSubtitle)
        paste.render(
            isOn: state.pasteAutomatically,
            isEnabled: state.isPasteEditable,
            subtitle: state.pasteSubtitle
        )
        drawnScales = state.interfaceScale.values
        interfaceScale.render(state.interfaceScale, isEnabled: true)
        interfaceScale.row.setSubtitle(state.interfaceScaleSubtitle)
        launch.render(isOn: state.launchAtLogin, isEnabled: true, subtitle: state.launchSubtitle)
    }
}
