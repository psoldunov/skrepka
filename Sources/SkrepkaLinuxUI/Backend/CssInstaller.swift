import CGtk4

/// Installs a stylesheet on the default display, one per ``Slot``.
///
/// Each slot has one provider for the life of the display, and installing
/// again reloads it in place — so restyling on every appearance change
/// replaces the old rules rather than stacking a new provider on top of them.
/// See `skrepka_css_load` in `Sources/CGtk4/style.h`.
enum CssInstaller {
    /// Who a stylesheet belongs to. The raw value keys the provider on the
    /// display, so two slots never overwrite each other.
    enum Slot: String {
        case picker = "skrepka-css-picker"
        case settings = "skrepka-css-settings"
    }

    /// Replaces `slot`'s rules with `css`. Call after GTK has opened the
    /// display; before that there is nothing to install on and it does
    /// nothing.
    static func install(_ css: String, slot: Slot) {
        skrepka_css_load(slot.rawValue, css)
    }
}
