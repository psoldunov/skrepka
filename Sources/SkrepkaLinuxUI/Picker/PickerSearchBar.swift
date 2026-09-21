import CGtk4

/// The search row along the top of the panel: a magnifier, a frameless entry,
/// and — only while the query is non-empty — the result count and a clear
/// button, matching the macOS `SearchField`.
///
/// Owns the entry so the window can focus it and read it, but the window keeps
/// the key controller: navigation and Return are intercepted there in the
/// capture phase, and only a `.type` reaches this entry.
final class PickerSearchBar {
    let root: UnsafeMutablePointer<GtkWidget>
    private let entryWidget: UnsafeMutablePointer<GtkWidget>
    private let entry: OpaquePointer
    private let countLabel: UnsafeMutablePointer<GtkWidget>
    private let clearButton: UnsafeMutablePointer<GtkWidget>

    /// Fires as the field changes, with its current contents.
    var onQueryChanged: ((String) -> Void)?

    init?() {
        guard let root = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10, "skrepka-search"),
            let magnifier = Build.icon(["system-search-symbolic", "edit-find-symbolic"]),
            let entryWidget = gtk_entry_new(),
            let entry = skrepka_as_editable(entryWidget),
            let gtkEntry = skrepka_as_entry(entryWidget),
            let countLabel = Build.label("", "skrepka-search-count"),
            let clearButton = gtk_button_new(),
            let clearImage = Build.icon(["edit-clear-symbolic", "window-close-symbolic"])
        else { return nil }

        gtk_entry_set_placeholder_text(gtkEntry, "Search clipboard…")
        gtk_entry_set_has_frame(gtkEntry, 0)
        gtk_widget_add_css_class(entryWidget, "skrepka-search-entry")
        gtk_widget_set_hexpand(entryWidget, 1)
        gtk_widget_set_size_request(root, -1, 50)

        gtk_button_set_child(skrepka_as_button(clearButton), clearImage)
        gtk_widget_add_css_class(clearButton, "skrepka-search-clear")
        gtk_widget_set_valign(magnifier, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(countLabel, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(clearButton, GTK_ALIGN_CENTER)

        Build.append(root, magnifier)
        Build.append(root, entryWidget)
        Build.append(root, countLabel)
        Build.append(root, clearButton)

        self.root = root
        self.entryWidget = entryWidget
        self.entry = entry
        self.countLabel = countLabel
        self.clearButton = clearButton

        showResults(count: 0, hasQuery: false)
        wire()
    }

    private func wire() {
        GtkSignal.connect(UnsafeMutableRawPointer(entry), "changed") { [weak self] in
            guard let self else { return }
            self.onQueryChanged?(self.text)
        }
        GtkSignal.connect(UnsafeMutableRawPointer(clearButton), "clicked") { [weak self] in
            self?.text = ""
        }
    }

    var text: String {
        get {
            guard let raw = gtk_editable_get_text(entry) else { return "" }
            return String(cString: raw)
        }
        set { gtk_editable_set_text(entry, newValue) }
    }

    func focus() {
        _ = gtk_widget_grab_focus(entryWidget)
    }

    /// Shows the count and clear button only when there is a query, the way the
    /// macOS field does.
    func showResults(count: Int, hasQuery: Bool) {
        gtk_widget_set_visible(countLabel, hasQuery ? 1 : 0)
        gtk_widget_set_visible(clearButton, hasQuery ? 1 : 0)
        guard hasQuery, let label = skrepka_as_label(countLabel) else { return }
        gtk_label_set_text(label, "\(count)")
    }
}
