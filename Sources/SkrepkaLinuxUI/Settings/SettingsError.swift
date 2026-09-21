/// Why the Settings window could not be built.
enum SettingsError: Error, CustomStringConvertible {
    /// GTK returned no widget. Practically unreachable — GLib aborts on
    /// allocation failure first — and not worth a force-unwrap to pretend
    /// otherwise.
    case widgetCreationFailed

    var description: String {
        "The Settings window could not be built."
    }
}
