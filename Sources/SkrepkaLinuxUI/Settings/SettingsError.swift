/// Why the Settings window could not start.
enum SettingsError: Error, CustomStringConvertible {
    /// GTK returned no widget. Practically unreachable — GLib aborts on
    /// allocation failure first — and not worth a force-unwrap to pretend
    /// otherwise.
    case widgetCreationFailed
    /// No Wayland or X11 display to open, which is what an ssh session looks
    /// like.
    case noDisplay

    var description: String {
        switch self {
        case .widgetCreationFailed:
            "The Settings window could not be built."
        case .noDisplay:
            """
            skrepka-settings could not open a display. Run it from a desktop session — \
            pairing and the device list are also available from the skrepka command.
            """
        }
    }
}
