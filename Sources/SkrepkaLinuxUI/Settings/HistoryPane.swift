import CGtk4

/// The History pane's widgets: the three figures, retention, and Clear….
///
/// Decides nothing: ``render(_:)`` copies a ``HistoryPaneState`` onto the
/// widgets, and each control reports the value the user chose.
final class HistoryPane {
    /// The item limit chosen; 0 for unlimited.
    var onKeepAtMost: ((Int) -> Void)?
    /// The age limit chosen, in days; 0 for never.
    var onDiscardAfter: ((Int) -> Void)?
    var onClear: (() -> Void)?
    var onDismissBanner: (() -> Void)?

    let page: SettingsPage
    private let banner: SyncBanner
    private let tiles: [MetricTile]
    private let keepAtMost: SettingsDropDownRow
    private let discardAfter: SettingsDropDownRow
    private let clear: GtkWidgetPointer
    private var drawn: HistoryPaneState?

    init() throws {
        guard let figures = GtkBuild.box(vertical: false, spacing: 10),
            let clear = GtkBuild.button("Clear…", classes: [SettingsStyle.destructive])
        else { throw SettingsError.widgetCreationFailed }
        let page = try SettingsPage(title: SettingsSection.history.title)
        let banner = try SyncBanner()
        gtk_box_set_homogeneous(skrepka_as_box(figures), 1)
        let tiles = try ["Entries", "Pinned", "Images"].map { try MetricTile(label: $0) }
        for tile in tiles {
            GtkBuild.append(tile.widget, to: figures)
        }

        let retention = try SettingsCard(
            title: "Retention", footer: "Pinned entries are never discarded, whatever these say.")
        let keepAtMost = try SettingsDropDownRow(
            title: "Keep at most", icon: ["view-list-symbolic", "format-justify-left-symbolic"])
        let discardAfter = try SettingsDropDownRow(
            title: "Discard after", icon: ["x-office-calendar-symbolic", "document-open-recent-symbolic"])
        retention.add(keepAtMost.row.widget)
        retention.add(discardAfter.row.widget)

        let stored = try SettingsCard(
            title: "Stored data",
            footer: "History stays on this device, and leaves it only for devices you pair with.")
        let clearRow = try SettingsRow(
            title: "Clear history",
            subtitle: "Remove stored entries from this device.",
            icon: ["user-trash-symbolic", "edit-delete-symbolic"])
        clearRow.addTrailing(clear)
        stored.add(clearRow.widget)

        for child in [banner.widget, figures, retention.widget, stored.widget] {
            page.append(child)
        }
        self.page = page
        self.banner = banner
        self.tiles = tiles
        self.keepAtMost = keepAtMost
        self.discardAfter = discardAfter
        self.clear = clear
        connect()
    }

    private func connect() {
        keepAtMost.onSelect = { [weak self] index in
            guard let values = self?.drawn?.keepAtMost.values, values.indices.contains(index) else { return }
            self?.onKeepAtMost?(values[index])
        }
        discardAfter.onSelect = { [weak self] index in
            guard let values = self?.drawn?.discardAfter.values, values.indices.contains(index) else {
                return
            }
            self?.onDiscardAfter?(values[index])
        }
        banner.onDismiss = { [weak self] in self?.onDismissBanner?() }
        GtkSignal.connect(UnsafeMutableRawPointer(clear), "clicked") { [weak self] in
            self?.onClear?()
        }
    }

    func render(_ state: HistoryPaneState) {
        guard state != drawn else { return }
        drawn = state
        banner.render(state.banner)
        for (tile, text) in zip(tiles, [state.entries, state.pinned, state.images]) {
            tile.render(text)
        }
        keepAtMost.render(state.keepAtMost, isEnabled: state.isEditable)
        discardAfter.render(state.discardAfter, isEnabled: state.isEditable)
        gtk_button_set_label(skrepka_as_button(clear), state.clearTitle)
        GtkBuild.setEnabled(clear, state.isClearEnabled)
    }
}
