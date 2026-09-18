import CGtk4

/// A GTK widget, as every constructor returns one.
typealias GtkWidgetPointer = UnsafeMutablePointer<GtkWidget>

/// The handful of widget recipes the Settings window repeats.
///
/// Every GTK constructor imports as optional, so every recipe does too; the
/// caller decides what a missing widget means, the way ``PaletteWindow``'s
/// initialiser does. In practice GLib aborts on allocation failure before any
/// of these can return nil.
enum GtkBuild {
    /// A left-aligned label. Plain text, never markup — device names arrive
    /// from the network, and a name is not allowed to become formatting.
    static func label(
        _ text: String,
        classes: [String] = [],
        wraps: Bool = false,
        centred: Bool = false
    ) -> GtkWidgetPointer? {
        guard let widget = gtk_label_new(text) else { return nil }
        let label = skrepka_as_label(widget)
        gtk_label_set_xalign(label, centred ? 0.5 : 0)
        if wraps {
            gtk_label_set_wrap(label, 1)
            gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
        }
        if centred {
            gtk_label_set_justify(label, GTK_JUSTIFY_CENTER)
        }
        style(widget, classes)
        return widget
    }

    /// Lets the mouse select a label's text, and keeps it out of the focus
    /// chain.
    ///
    /// Out of the chain because a selectable label is focusable by default,
    /// and GTK gives a new window's focus to the first focusable widget — which
    /// selects that label's whole text the moment the window appears, and puts
    /// Tab's first stop on a line of text rather than a control. Copying still
    /// works from the selection and the label's context menu.
    static func makeCopyable(_ label: GtkWidgetPointer) {
        gtk_label_set_selectable(skrepka_as_label(label), 1)
        gtk_widget_set_focusable(label, 0)
    }

    static func box(vertical: Bool, spacing: Int32, classes: [String] = []) -> GtkWidgetPointer? {
        let orientation = vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL
        guard let widget = gtk_box_new(orientation, spacing) else { return nil }
        style(widget, classes)
        return widget
    }

    static func button(_ title: String, classes: [String] = []) -> GtkWidgetPointer? {
        guard let widget = gtk_button_new_with_label(title) else { return nil }
        style(widget, classes)
        return widget
    }

    /// A themed border around `child` — how a card is drawn here. A frame is
    /// the one bordered container every GTK theme styles, where a style class
    /// such as `boxed-list` exists in some themes and not others.
    static func frame(around child: GtkWidgetPointer) -> GtkWidgetPointer? {
        guard let widget = gtk_frame_new(nil) else { return nil }
        gtk_frame_set_child(skrepka_as_frame(widget), child)
        return widget
    }

    static func append(_ child: GtkWidgetPointer, to box: GtkWidgetPointer) {
        gtk_box_append(skrepka_as_box(box), child)
    }

    static func setText(_ label: GtkWidgetPointer, _ text: String) {
        gtk_label_set_text(skrepka_as_label(label), text)
    }

    static func setVisible(_ widget: GtkWidgetPointer, _ isVisible: Bool) {
        gtk_widget_set_visible(widget, isVisible ? 1 : 0)
    }

    static func setEnabled(_ widget: GtkWidgetPointer, _ isEnabled: Bool) {
        gtk_widget_set_sensitive(widget, isEnabled ? 1 : 0)
    }

    static func margins(_ widget: GtkWidgetPointer, vertical: Int32, horizontal: Int32) {
        gtk_widget_set_margin_top(widget, vertical)
        gtk_widget_set_margin_bottom(widget, vertical)
        gtk_widget_set_margin_start(widget, horizontal)
        gtk_widget_set_margin_end(widget, horizontal)
    }

    private static func style(_ widget: GtkWidgetPointer, _ classes: [String]) {
        for name in classes {
            gtk_widget_add_css_class(widget, name)
        }
    }
}
