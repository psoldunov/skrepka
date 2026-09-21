import CGtk4

/// A message the app has to tell the user when no window of its own is open —
/// a Clear History from the tray menu that the daemon refused.
enum AppAlert {
    /// Shows `message` with `detail` under it and one button. Not modal to
    /// anything: there is no window to be modal to.
    static func show(message: String, detail: String) {
        guard let dialog = skrepka_alert_dialog_new(message) else { return }
        gtk_alert_dialog_set_detail(dialog, detail)
        gtk_alert_dialog_show(dialog, nil)
        // The dialog on screen holds its own reference.
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }
}
