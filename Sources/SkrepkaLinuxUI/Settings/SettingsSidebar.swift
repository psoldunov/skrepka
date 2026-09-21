import CGtk4

/// The Settings window's left column: the app's mark and name, and one big
/// row per ``SettingsSection``.
///
/// Rows are 48px tall and a list box moves its selection with the arrow keys,
/// so the Steam Deck's d-pad — which Steam Input sends as arrows — walks the
/// sections as well as a finger or the trackpad does.
final class SettingsSidebar {
    /// The section the user picked.
    var onSelect: ((SettingsSection) -> Void)?

    let widget: GtkWidgetPointer
    private let list: OpaquePointer
    private let mark: GtkWidgetPointer
    private var accent = RGBColor(red: 10 / 255, green: 122 / 255, blue: 1)

    init() throws {
        guard let column = GtkBuild.box(vertical: true, spacing: 0, classes: [SettingsStyle.sidebar]),
            let listWidget = gtk_list_box_new(),
            let list = skrepka_as_list_box(listWidget),
            let mark = gtk_drawing_area_new()
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_add_css_class(listWidget, SettingsStyle.nav)
        gtk_list_box_set_selection_mode(list, GTK_SELECTION_BROWSE)
        for section in SettingsSection.allCases {
            if let row = Self.row(section) { gtk_list_box_append(list, row) }
        }
        GtkBuild.append(try Self.identity(mark: mark), to: column)
        GtkBuild.append(listWidget, to: column)

        self.widget = column
        self.list = list
        self.mark = mark
        SidebarSignal.onRowSelected(list) { [weak self] index in
            guard let self, SettingsSection.allCases.indices.contains(index) else { return }
            self.onSelect?(SettingsSection.allCases[index])
        }
        PickerRowSignals.setDrawFunc(mark) { [weak self] cairo, width, height in
            let frame = MarkRenderer.Frame(x: 5, y: 5, width: Double(width) - 10, height: Double(height) - 10)
            MarkRenderer.fillMark(
                cairo, in: frame, color: self?.accent ?? RGBColor(red: 0, green: 0, blue: 1))
        }
    }

    /// Selects `section`'s row, which shows its page through ``onSelect``.
    func select(_ section: SettingsSection) {
        guard let index = SettingsSection.allCases.firstIndex(of: section),
            let row = gtk_list_box_get_row_at_index(list, Int32(index))
        else { return }
        gtk_list_box_select_row(list, row)
    }

    /// Redraws the mark in the desktop's accent.
    func apply(_ appearance: AppearancePreference) {
        accent = appearance.accent ?? RGBColor(red: 10 / 255, green: 122 / 255, blue: 1)
        gtk_widget_queue_draw(mark)
    }

    private static func identity(mark: GtkWidgetPointer) throws -> GtkWidgetPointer {
        guard let line = GtkBuild.box(vertical: false, spacing: 12, classes: [SettingsStyle.identity]),
            let text = GtkBuild.box(vertical: true, spacing: 1),
            let name = GtkBuild.label("Skrepka", classes: [SettingsStyle.identityName]),
            let tagline = GtkBuild.label("Clipboard history", classes: [SettingsStyle.identityVersion])
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_add_css_class(mark, "skrepka-identity-mark")
        gtk_widget_set_size_request(mark, 40, 40)
        gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(text, GTK_ALIGN_CENTER)
        GtkBuild.append(name, to: text)
        GtkBuild.append(tagline, to: text)
        GtkBuild.append(mark, to: line)
        GtkBuild.append(text, to: line)
        return line
    }

    private static func row(_ section: SettingsSection) -> GtkWidgetPointer? {
        guard let line = GtkBuild.box(vertical: false, spacing: 12),
            let icon = SettingsWidgets.icon(section.iconNames),
            let label = GtkBuild.label(section.title)
        else { return nil }
        gtk_widget_set_valign(line, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(line, 1)
        GtkBuild.append(icon, to: line)
        GtkBuild.append(label, to: line)
        return line
    }
}
