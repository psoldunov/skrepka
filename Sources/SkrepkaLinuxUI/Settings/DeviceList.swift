import CGtk4

/// "Devices": every paired device and every device in sight, with the one
/// decision the user can take about each, and Sync Now beneath them.
///
/// The rows are rebuilt rather than updated in place, and only when what they
/// show has changed — ``PeerRowState`` is `Hashable` and coarse on purpose, so
/// a poll that moved nothing on screen rebuilds nothing, which is most polls.
final class DeviceList {
    var onPair: ((String) -> Void)?
    var onUnpair: ((String) -> Void)?
    var onLivePush: ((String, Bool) -> Void)?
    var onSyncNow: (() -> Void)?

    let widget: GtkWidgetPointer
    /// GTK's list box is only forward-declared in its public headers, so it
    /// imports as an opaque pointer — see ``PaletteWindow``.
    private let list: OpaquePointer
    private let frame: GtkWidgetPointer
    private let empty: GtkWidgetPointer
    private let syncRow: GtkWidgetPointer
    private let syncNow: GtkWidgetPointer
    /// What the list is showing now.
    private var shown: [PeerRowState] = []
    /// The live-push switches, kept alive for as long as their rows are:
    /// each one's handler holds only a weak reference to it.
    private var switches: [SettingsSwitchRow] = []

    init() throws {
        guard let column = GtkBuild.box(vertical: true, spacing: 12),
            let listWidget = gtk_list_box_new(),
            let list = skrepka_as_list_box(listWidget),
            let frame = GtkBuild.frame(around: listWidget),
            let empty = GtkBuild.label("", classes: [SettingsStyle.secondary], wraps: true, centred: true),
            let syncRow = GtkBuild.box(vertical: false, spacing: 12),
            let syncNow = GtkBuild.button("Sync Now"),
            let footer = GtkBuild.label(
                """
                Devices exchange history every half minute, and what you copy crosses \
                immediately where live clipboard is on.
                """,
                classes: [SettingsStyle.secondary],
                wraps: true
            )
        else { throw SettingsError.widgetCreationFailed }
        gtk_list_box_set_selection_mode(list, GTK_SELECTION_NONE)
        gtk_list_box_set_show_separators(list, 1)
        GtkBuild.margins(empty, vertical: 16, horizontal: 12)
        gtk_widget_set_valign(syncNow, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(footer, 1)
        GtkBuild.append(syncNow, to: syncRow)
        GtkBuild.append(footer, to: syncRow)
        for child in [frame, empty, syncRow] {
            GtkBuild.append(child, to: column)
        }

        self.widget = column
        self.list = list
        self.frame = frame
        self.empty = empty
        self.syncRow = syncRow
        self.syncNow = syncNow
        GtkSignal.connect(UnsafeMutableRawPointer(syncNow), "clicked") { [weak self] in
            self?.onSyncNow?()
        }
    }

    func render(_ state: SyncPaneState) {
        if state.rows != shown {
            rebuild(state.rows)
        }
        GtkBuild.setVisible(frame, !shown.isEmpty)
        GtkBuild.setText(empty, state.emptyMessage ?? "")
        GtkBuild.setVisible(empty, state.emptyMessage != nil)
        GtkBuild.setVisible(syncRow, state.showsSyncNow)
        GtkBuild.setEnabled(syncNow, state.isSyncNowEnabled)
    }

    private func rebuild(_ rows: [PeerRowState]) {
        gtk_list_box_remove_all(list)
        switches = []
        var built: [PeerRowState] = []
        for row in rows {
            // A row GTK would not build is left out and the rest still shown.
            // `shown` then differs from the state, so the next render tries
            // again rather than believing the list is complete.
            guard let widget = try? makeRow(row) else { continue }
            gtk_list_box_append(list, widget)
            built.append(row)
        }
        shown = built
    }

    private func makeRow(_ row: PeerRowState) throws -> GtkWidgetPointer {
        guard let column = GtkBuild.box(vertical: true, spacing: 0),
            let platform = GtkBuild.label(row.platform, classes: [SettingsStyle.secondary]),
            let button = actionButton(for: row)
        else { throw SettingsError.widgetCreationFailed }
        let line = try SettingsRow(title: row.title, subtitle: row.subtitle)
        line.addTrailing(platform)
        line.addTrailing(button)
        GtkBuild.append(line.widget, to: column)

        if let live = row.livePush {
            let toggle = try SettingsSwitchRow(title: "Live clipboard", isOn: live.isOn)
            toggle.render(isOn: live.isOn, isEnabled: live.isEnabled, subtitle: live.explanation)
            toggle.setAccessibleLabel("Live clipboard with \(row.title)")
            let id = row.id
            toggle.onToggle = { [weak self] isOn in self?.onLivePush?(id, isOn) }
            // Indented under the device it belongs to, as on a Mac.
            gtk_widget_set_margin_start(toggle.row.widget, 36)
            GtkBuild.append(toggle.row.widget, to: column)
            switches.append(toggle)
        }
        return column
    }

    private func actionButton(for row: PeerRowState) -> GtkWidgetPointer? {
        let id = row.id
        switch row.action {
        case .pair(let isEnabled):
            guard let button = GtkBuild.button("Pair…") else { return nil }
            GtkBuild.setEnabled(button, isEnabled)
            GtkSignal.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                self?.onPair?(id)
            }
            return button
        case .unpair(let isEnabled):
            guard let button = GtkBuild.button("Unpair") else { return nil }
            GtkBuild.setEnabled(button, isEnabled)
            GtkSignal.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
                self?.onUnpair?(id)
            }
            return button
        }
    }
}
