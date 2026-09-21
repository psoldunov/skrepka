import CGtk4

/// Small builders that take the repetition out of assembling the picker's
/// widget tree: a boxed constructor plus a CSS class, the box-append cast, and
/// the label tweaks every row needs. Each returns the optional GTK hands back,
/// so a caller still guards once — the raw-interop tax shim.h describes — but
/// says what it is building rather than which macro it is casting through.
enum Build {
    static func box(
        _ orientation: GtkOrientation,
        spacing: Int32 = 0,
        _ cssClass: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let widget = gtk_box_new(orientation, spacing) else { return nil }
        if let cssClass { gtk_widget_add_css_class(widget, cssClass) }
        return widget
    }

    static func label(_ text: String, _ cssClass: String? = nil) -> UnsafeMutablePointer<GtkWidget>? {
        guard let widget = gtk_label_new(text) else { return nil }
        if let cssClass { gtk_widget_add_css_class(widget, cssClass) }
        return widget
    }

    /// An image showing the first themed icon `names` the theme has.
    static func icon(_ names: [String], _ cssClass: String? = nil) -> UnsafeMutablePointer<GtkWidget>? {
        guard let widget = gtk_image_new(), let image = skrepka_as_image(widget) else { return nil }
        skrepka_image_set_icon_names(image, names.first, names.dropFirst().first, names.dropFirst(2).first)
        if let cssClass { gtk_widget_add_css_class(widget, cssClass) }
        return widget
    }

    /// Appends `child` to a box built as a widget, casting once.
    static func append(_ box: UnsafeMutablePointer<GtkWidget>, _ child: UnsafeMutablePointer<GtkWidget>) {
        guard let casted = skrepka_as_box(box) else { return }
        gtk_box_append(casted, child)
    }

    /// A leading-aligned, single-line, tail-truncated label — the shape both
    /// the title and the subtitle use.
    static func leadingLabel(
        _ text: String,
        _ cssClass: String
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let widget = label(text, cssClass), let casted = skrepka_as_label(widget) else {
            return nil
        }
        gtk_label_set_xalign(casted, 0)
        gtk_label_set_ellipsize(casted, PANGO_ELLIPSIZE_END)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_halign(widget, GTK_ALIGN_FILL)
        return widget
    }
}
