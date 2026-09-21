import CGtk4

/// A ``SettingsRow`` whose control is a drop-down — the History pane's "Keep
/// at most" and "Discard after".
///
/// Reports only the user's choices, for ``SettingsSwitchRow``'s reason:
/// ``render(_:isEnabled:)`` moving the selection causes the same
/// `notify::selected` a choice does.
final class SettingsDropDownRow {
    /// The index chosen.
    var onSelect: ((Int) -> Void)?

    let row: SettingsRow
    private let control: GtkWidgetPointer
    private var labels: [String] = []
    private var isRendering = false

    init(title: String, icon: [String] = []) throws {
        guard let control = skrepka_drop_down_new() else { throw SettingsError.widgetCreationFailed }
        let row = try SettingsRow(title: title, subtitle: nil, icon: icon)
        gtk_widget_set_valign(control, GTK_ALIGN_CENTER)
        skrepka_set_accessible_label(control, title)
        row.addTrailing(control)
        self.row = row
        self.control = control

        GtkSignal.onChange(of: "selected", on: UnsafeMutableRawPointer(control)) { [weak self] in
            guard let self, !self.isRendering else { return }
            let index = Int(gtk_drop_down_get_selected(skrepka_as_drop_down(self.control)))
            guard index < self.labels.count else { return }
            self.onSelect?(index)
        }
    }

    func render(_ choice: HistoryPaneState.Choice, isEnabled: Bool) {
        isRendering = true
        defer { isRendering = false }
        let dropDown = skrepka_as_drop_down(control)
        if choice.labels != labels {
            replaceLabels(choice.labels, in: dropDown)
        }
        if Int(gtk_drop_down_get_selected(dropDown)) != choice.selected {
            gtk_drop_down_set_selected(dropDown, UInt32(choice.selected))
        }
        GtkBuild.setEnabled(control, isEnabled)
    }

    private func replaceLabels(_ next: [String], in dropDown: OpaquePointer?) {
        skrepka_drop_down_clear(dropDown)
        for label in next {
            skrepka_drop_down_append(dropDown, label)
        }
        labels = next
    }
}
