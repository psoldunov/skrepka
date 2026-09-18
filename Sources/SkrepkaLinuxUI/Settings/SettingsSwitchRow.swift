import CGtk4

/// A ``SettingsRow`` whose control is a switch.
///
/// The switch reports only the user's flips. ``render(isOn:isEnabled:subtitle:)``
/// writing it causes the same `notify::active` a flip does, so the row ignores
/// notifications while it is rendering — otherwise every poll that redrew the
/// pane would send the switch's own state back to the daemon as a request.
final class SettingsSwitchRow {
    var onToggle: ((Bool) -> Void)?

    let row: SettingsRow
    private let control: GtkWidgetPointer
    private var isRendering = false

    init(title: String, subtitle: String? = nil, isOn: Bool = false) throws {
        guard let control = gtk_switch_new() else { throw SettingsError.widgetCreationFailed }
        let row = try SettingsRow(title: title, subtitle: subtitle)
        // Set before the handler is connected, so the first position is not a
        // flip either.
        gtk_switch_set_active(skrepka_as_switch(control), isOn ? 1 : 0)
        gtk_widget_set_valign(control, GTK_ALIGN_CENTER)
        skrepka_set_accessible_label(control, title)
        row.addTrailing(control)
        self.row = row
        self.control = control

        GtkSignal.onChange(of: "active", on: UnsafeMutableRawPointer(control)) { [weak self] in
            guard let self, !self.isRendering else { return }
            self.onToggle?(self.isOn)
        }
    }

    var isOn: Bool {
        gtk_switch_get_active(skrepka_as_switch(control)) != 0
    }

    /// Names the switch for a screen reader when its title alone would be
    /// ambiguous — one "Live clipboard" switch per device.
    func setAccessibleLabel(_ label: String) {
        skrepka_set_accessible_label(control, label)
    }

    func render(isOn: Bool, isEnabled: Bool, subtitle: String) {
        isRendering = true
        defer { isRendering = false }
        gtk_switch_set_active(skrepka_as_switch(control), isOn ? 1 : 0)
        GtkBuild.setEnabled(control, isEnabled)
        row.setSubtitle(subtitle)
    }
}
