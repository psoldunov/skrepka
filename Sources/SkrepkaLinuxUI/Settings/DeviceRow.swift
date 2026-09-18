import CGtk4

/// One device in the Devices list: the widgets a ``PeerRowState`` is drawn on.
///
/// Kept for as long as the device stays in the list as the same kind of row —
/// see ``DeviceListPlan`` — and redrawn in place, so the switch or button a
/// person just used is the one still on screen, with the keyboard focus still
/// on it. Decides nothing: ``render(_:)`` copies a state onto the widgets, and
/// the two closures report what the person did.
final class DeviceRow {
    /// The `GtkListBoxRow`, which is what the list inserts and removes.
    let widget: GtkWidgetPointer
    let key: DeviceListPlan.Key

    private let line: SettingsRow
    private let platform: GtkWidgetPointer
    private let button: GtkWidgetPointer
    /// Retained here because its handler holds only a weak reference to it.
    private let livePush: SettingsSwitchRow?
    private var drawn: PeerRowState?

    /// The key a state's row is kept under.
    static func key(_ state: PeerRowState) -> DeviceListPlan.Key {
        guard case .unpair = state.action else { return DeviceListPlan.Key(id: state.id, isPaired: false) }
        return DeviceListPlan.Key(id: state.id, isPaired: true)
    }

    /// - Parameters:
    ///   - onAction: Pair… or Unpair, whichever this kind of row carries.
    ///   - onLivePush: The live-clipboard switch, flipped to the value given.
    init(
        _ state: PeerRowState,
        onAction: @escaping () -> Void,
        onLivePush: @escaping (Bool) -> Void
    ) throws {
        let key = Self.key(state)
        guard let widget = gtk_list_box_row_new(),
            let column = GtkBuild.box(vertical: true, spacing: 0),
            let platform = GtkBuild.label(state.platform, classes: [SettingsStyle.secondary]),
            let button = GtkBuild.button(key.isPaired ? "Unpair" : "Pair…")
        else { throw SettingsError.widgetCreationFailed }
        let line = try SettingsRow(title: state.title, subtitle: state.subtitle)
        line.addTrailing(platform)
        line.addTrailing(button)
        GtkBuild.append(line.widget, to: column)
        GtkSignal.connect(UnsafeMutableRawPointer(button), "clicked", onAction)

        var livePush: SettingsSwitchRow?
        if key.isPaired {
            let toggle = try SettingsSwitchRow(title: "Live clipboard", isOn: state.livePush?.isOn ?? false)
            toggle.onToggle = onLivePush
            // Indented under the device it belongs to, as on a Mac.
            gtk_widget_set_margin_start(toggle.row.widget, 36)
            GtkBuild.append(toggle.row.widget, to: column)
            livePush = toggle
        }
        gtk_list_box_row_set_child(skrepka_as_list_box_row(widget), column)

        self.widget = widget
        self.key = key
        self.line = line
        self.platform = platform
        self.button = button
        self.livePush = livePush
        render(state)
    }

    func render(_ state: PeerRowState) {
        guard state != drawn else { return }
        drawn = state
        line.setTitle(state.title)
        line.setSubtitle(state.subtitle)
        GtkBuild.setText(platform, state.platform)
        GtkBuild.setEnabled(button, state.action.isEnabled)
        if let toggle = livePush, let live = state.livePush {
            toggle.render(isOn: live.isOn, isEnabled: live.isEnabled, subtitle: live.explanation)
            // One "Live clipboard" switch per device, so the title alone
            // would not tell a screen reader which.
            toggle.setAccessibleLabel("Live clipboard with \(state.title)")
        }
    }
}
