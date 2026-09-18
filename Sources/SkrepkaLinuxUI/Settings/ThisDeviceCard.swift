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
        guard let card = GtkBuild.box(vertical: true, spacing: 0),
            let nameLabel = GtkBuild.label("…"),
            let codeLabel = GtkBuild.label("", classes: [SettingsStyle.monospace])
        else { throw SettingsError.widgetCreationFailed }
        // Copyable, because half of what this card is for is reading the code
        // out to somebody standing at the other machine, or pasting it.
        GtkBuild.makeCopyable(nameLabel)
        GtkBuild.makeCopyable(codeLabel)

        let name = try SettingsRow(title: "Name", subtitle: nil)
        name.addTrailing(nameLabel)
        let code = try SettingsRow(
            title: "This device's code", subtitle: "Shown on the other machine when you pair.")
        code.addTrailing(codeLabel)
        let pairing = try SettingsSwitchRow(title: "Allow new devices to pair")

        for row in [name.widget, code.widget, pairing.row.widget] {
            GtkBuild.append(row, to: card)
        }
        guard let frame = GtkBuild.frame(around: card) else { throw SettingsError.widgetCreationFailed }

        self.widget = frame
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
