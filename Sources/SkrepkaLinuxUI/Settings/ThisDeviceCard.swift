import CGtk4

/// "This device": its name, the code the other machine shows when pairing, and
/// the switch that opens the pairing window.
///
/// The switch has its own row rather than being implied by opening the window,
/// for the macOS pane's reason: what it does is accept connections from
/// machines this one has never met, which is a thing to turn on deliberately.
final class ThisDeviceCard {
    var onPairingSwitch: ((Bool) -> Void)? {
        get { pairing.onToggle }
        set { pairing.onToggle = newValue }
    }

    let widget: GtkWidgetPointer
    private let nameLabel: GtkWidgetPointer
    private let codeLabel: GtkWidgetPointer
    private let pairing: SettingsSwitchRow

    init() throws {
        guard let nameLabel = SettingsWidgets.value("…"),
            let codeLabel = SettingsWidgets.value("", isLiteral: true)
        else { throw SettingsError.widgetCreationFailed }
        // Copyable, because half of what this card is for is reading the code
        // out to somebody standing at the other machine, or pasting it.
        GtkBuild.makeCopyable(nameLabel)
        GtkBuild.makeCopyable(codeLabel)

        let name = try SettingsRow(title: "Name", subtitle: nil, icon: ["computer-symbolic"])
        name.addTrailing(nameLabel)
        let code = try SettingsRow(
            title: "This device's code",
            subtitle: "Shown on the other machine when you pair.",
            icon: ["channel-secure-symbolic", "security-high-symbolic"])
        code.addTrailing(codeLabel)
        let pairing = try SettingsSwitchRow(
            title: "Allow new devices to pair", icon: ["list-add-symbolic", "contact-new-symbolic"])
        let card = try SettingsCard(
            title: "This device",
            footer: """
                Skrepka shares history with devices you pair with, over the local \
                network only. Nothing is sent to a server.
                """)
        for row in [name.widget, code.widget, pairing.row.widget] {
            card.add(row)
        }

        self.widget = card.widget
        self.nameLabel = nameLabel
        self.codeLabel = codeLabel
        self.pairing = pairing
    }

    func render(name: String, code: String, pairing state: SyncPaneState.PairingSwitch) {
        GtkBuild.setText(nameLabel, name)
        GtkBuild.setText(codeLabel, code.isEmpty ? "—" : code)
        pairing.render(isOn: state.isOn, isEnabled: state.isEnabled, subtitle: state.subtitle)
    }
}
