import CGtk4

/// The Settings window's small widget recipes, on top of ``GtkBuild``'s.
enum SettingsWidgets {
    /// A themed icon drawn from the first name in `names` the theme has.
    static func icon(_ names: [String], classes: [String] = []) -> GtkWidgetPointer? {
        guard let widget = gtk_image_new() else { return nil }
        let third = names.count > 2 ? names[2] : nil
        skrepka_image_set_icon_names(skrepka_as_image(widget), names.first, names.dropFirst().first, third)
        for name in classes {
            gtk_widget_add_css_class(widget, name)
        }
        return widget
    }

    static func separator() -> GtkWidgetPointer? {
        gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)
    }

    /// A value on the right of a row: secondary text, right-aligned. Literal
    /// values — a path, a fingerprint — are monospaced, selectable and
    /// middle-ellipsised rather than wrapped.
    static func value(_ text: String, isLiteral: Bool = false) -> GtkWidgetPointer? {
        let classes = isLiteral ? [SettingsStyle.value, SettingsStyle.monospace] : [SettingsStyle.value]
        guard let label = GtkBuild.label(text, classes: classes) else { return nil }
        gtk_label_set_xalign(skrepka_as_label(label), 1)
        if isLiteral {
            GtkBuild.makeCopyable(label)
            gtk_label_set_ellipsize(skrepka_as_label(label), PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(skrepka_as_label(label), 46)
        }
        return label
    }

    /// A card's heading, set in capitals above it as on a Mac.
    static func heading(_ text: String) -> GtkWidgetPointer? {
        GtkBuild.label(text.uppercased(), classes: [SettingsStyle.heading])
    }

    /// The small print under a card.
    static func footer(_ text: String) -> GtkWidgetPointer? {
        GtkBuild.label(text, classes: [SettingsStyle.footer], wraps: true)
    }

    /// A status dot in a tone's colour.
    static func dot() -> GtkWidgetPointer? {
        guard let dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0) else { return nil }
        gtk_widget_add_css_class(dot, SettingsStyle.dot)
        gtk_widget_set_valign(dot, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(dot, GTK_ALIGN_CENTER)
        return dot
    }

    /// Replaces whichever tone class `widget` carries with `tone`.
    static func setTone(_ widget: GtkWidgetPointer, _ tone: String?) {
        for name in SettingsStyle.allTones {
            gtk_widget_remove_css_class(widget, name)
        }
        if let tone { gtk_widget_add_css_class(widget, tone) }
    }

    /// Removes every child of a box.
    static func empty(_ box: GtkWidgetPointer) {
        while let child = gtk_widget_get_first_child(box) {
            gtk_box_remove(skrepka_as_box(box), child)
        }
    }
}
