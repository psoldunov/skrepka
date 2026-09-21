import CGtk4

/// A figure over its label, on a card of its own — the History pane's
/// Entries, Pinned and Images, as the macOS pane draws them.
final class MetricTile {
    let widget: GtkWidgetPointer
    private let value: GtkWidgetPointer
    private let label: String

    init(label: String) throws {
        guard let tile = GtkBuild.box(vertical: true, spacing: 1, classes: [SettingsStyle.metric]),
            let value = GtkBuild.label("—", classes: [SettingsStyle.metricValue]),
            let caption = GtkBuild.label(label, classes: [SettingsStyle.metricLabel])
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_set_hexpand(tile, 1)
        GtkBuild.append(value, to: tile)
        GtkBuild.append(caption, to: tile)
        self.widget = tile
        self.value = value
        self.label = label
    }

    func render(_ text: String) {
        GtkBuild.setText(value, text)
        skrepka_set_accessible_label(widget, "\(text) \(label)")
    }
}
