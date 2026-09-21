import CGtk4

/// One line of a settings card: an optional icon, a title with a smaller line
/// under it, and a control or a value on the right.
///
/// The macOS pane's `SettingsRow`, so the two read as the same product: 13px
/// title, 11px secondary line, at least 48px tall so a finger or a Steam Deck
/// trackpad lands on it.
final class SettingsRow {
    let widget: GtkWidgetPointer
    private let titleLabel: GtkWidgetPointer
    private let subtitleLabel: GtkWidgetPointer
    private let trailing: GtkWidgetPointer

    init(title: String, subtitle: String?, icon: [String] = []) throws {
        guard let line = GtkBuild.box(vertical: false, spacing: 12, classes: [SettingsStyle.row]),
            let text = GtkBuild.box(vertical: true, spacing: 2),
            let titleLabel = GtkBuild.label(title, classes: [SettingsStyle.rowTitle], wraps: true),
            let subtitleLabel = GtkBuild.label(
                subtitle ?? "", classes: [SettingsStyle.secondary], wraps: true),
            let trailing = GtkBuild.box(vertical: false, spacing: 8)
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(trailing, GTK_ALIGN_CENTER)
        GtkBuild.setVisible(subtitleLabel, !(subtitle ?? "").isEmpty)

        if !icon.isEmpty, let image = SettingsWidgets.icon(icon, classes: [SettingsStyle.rowIcon]) {
            gtk_widget_set_valign(image, GTK_ALIGN_CENTER)
            GtkBuild.append(image, to: line)
        }
        GtkBuild.append(titleLabel, to: text)
        GtkBuild.append(subtitleLabel, to: text)
        GtkBuild.append(text, to: line)
        GtkBuild.append(trailing, to: line)

        self.widget = line
        self.titleLabel = titleLabel
        self.subtitleLabel = subtitleLabel
        self.trailing = trailing
    }

    /// Adds a control or a value at the right-hand end.
    func addTrailing(_ child: GtkWidgetPointer) {
        GtkBuild.append(child, to: trailing)
    }

    /// For a row that outlives its first title — a device whose name arrives
    /// once its link has said hello.
    func setTitle(_ text: String) {
        GtkBuild.setText(titleLabel, text)
    }

    func setSubtitle(_ text: String) {
        GtkBuild.setText(subtitleLabel, text)
        GtkBuild.setVisible(subtitleLabel, !text.isEmpty)
    }
}
