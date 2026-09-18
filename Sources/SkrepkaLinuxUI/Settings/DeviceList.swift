import CGtk4

/// "Devices": every paired device and every device in sight, with the one
/// decision the user can take about each, and Sync Now beneath them.
///
/// Rows are kept, not rebuilt: ``DeviceListPlan`` decides which devices
/// arrived, left or changed kind, only those rows are inserted or removed, and
/// every other one is redrawn in place. A poll that moved a subtitle, a flip on
/// its way, or a pairing opening over the window therefore leaves the
/// keyboard focus where the person put it.
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
    /// The rows on screen, in the order they are shown.
    private var rows: [DeviceRow] = []

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
        reconcile(state.rows)
        GtkBuild.setVisible(frame, !rows.isEmpty)
        GtkBuild.setText(empty, state.emptyMessage ?? "")
        GtkBuild.setVisible(empty, state.emptyMessage != nil)
        GtkBuild.setVisible(syncRow, state.showsSyncNow)
        GtkBuild.setEnabled(syncNow, state.isSyncNowEnabled)
    }

    /// Brings the rows on screen to `wanted`: out with the ones the plan
    /// removes, in with the ones it adds, and every row given its state.
    private func reconcile(_ wanted: [PeerRowState]) {
        let plan = DeviceListPlan.between(shown: rows.map(\.key), wanted: wanted.map(DeviceRow.key))
        let removed = Set(plan.removals)
        for row in rows where removed.contains(row.key) {
            gtk_list_box_remove(list, row.widget)
        }
        var kept = rows.filter { !removed.contains($0.key) }
        // A row GTK would not build is left out and the rest still shown, one
        // place further up. It is missing from `rows`, so the next render's
        // plan inserts it again rather than believing the list is complete.
        var skipped = 0
        for insertion in plan.insertions {
            guard let row = try? makeRow(wanted[insertion.index]) else {
                skipped += 1
                continue
            }
            let position = insertion.index - skipped
            gtk_list_box_insert(list, row.widget, Int32(position))
            kept.insert(row, at: position)
        }
        rows = kept

        let states = Dictionary(
            wanted.map { (DeviceRow.key($0), $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            if let state = states[row.key] { row.render(state) }
        }
    }

    private func makeRow(_ state: PeerRowState) throws -> DeviceRow {
        let id = state.id
        let isPaired = DeviceRow.key(state).isPaired
        return try DeviceRow(
            state,
            onAction: { [weak self] in
                if isPaired { self?.onUnpair?(id) } else { self?.onPair?(id) }
            },
            onLivePush: { [weak self] isOn in self?.onLivePush?(id, isOn) }
        )
    }
}
