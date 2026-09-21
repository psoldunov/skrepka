import CGtk4

/// One section's page: a scroller holding the section's title and its cards,
/// eighteen pixels apart, as the macOS window spaces them.
final class SettingsPage {
    /// The scroller, which is what the window's stack holds.
    let root: GtkWidgetPointer
    private let column: GtkWidgetPointer

    init(title: String) throws {
        guard let scroller = gtk_scrolled_window_new(),
            let column = GtkBuild.box(vertical: true, spacing: 18, classes: [SettingsStyle.page]),
            let heading = GtkBuild.label(title, classes: [SettingsStyle.pageTitle])
        else { throw SettingsError.widgetCreationFailed }
        let scroll = skrepka_as_scrolled_window(scroller)
        gtk_scrolled_window_set_policy(scroll, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroll, column)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_widget_set_vexpand(scroller, 1)
        GtkBuild.append(heading, to: column)
        self.root = scroller
        self.column = column
    }

    func append(_ child: GtkWidgetPointer) {
        GtkBuild.append(child, to: column)
    }
}
