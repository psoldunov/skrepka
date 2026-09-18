import CGtk4

/// The Settings window: an ordinary toplevel holding the Sync pane.
///
/// Ordinary on purpose — not a layer-shell surface like the picker. Settings
/// is a window the user opens from the launcher, moves, and closes; it takes
/// focus the way every other window does, and it needs nothing a plain
/// `xdg_toplevel` does not give it on every compositor, GNOME included.
///
/// One pane for now, the one this window was built for. Retention and
/// exclusions join it as panes beside Sync when the daemon's interface can set
/// them.
final class SettingsWindow {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let window: UnsafeMutablePointer<GtkWindow>
    private let controller: SyncController

    /// - Parameter onClosed: Called as the window closes. The application
    ///   is kept running until the link has shut down.
    init(
        application: UnsafeMutablePointer<GtkApplication>,
        link: DaemonLink,
        inbox: MainLoopInbox<SyncEvent>,
        onClosed: @escaping () -> Void
    ) throws {
        guard let widget = gtk_application_window_new(application),
            let window = skrepka_as_window(widget),
            let scroller = gtk_scrolled_window_new()
        else { throw SettingsError.widgetCreationFailed }
        gtk_window_set_title(window, "Skrepka Settings")
        // Sized for the Steam Deck's 1280×800 first: tall enough for a paired
        // Mac and two devices in sight without scrolling, short enough to sit
        // inside the panel with room to spare.
        gtk_window_set_default_size(window, 580, 680)

        let pane = try SyncPane()
        let scroll = skrepka_as_scrolled_window(scroller)
        gtk_scrolled_window_set_policy(scroll, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scroll, pane.root)
        gtk_window_set_child(window, scroller)

        let dialog = try PairingDialog(parent: window)
        self.application = application
        self.window = window
        self.controller = try SyncController(
            pane: pane, dialog: dialog, parent: window, link: link, inbox: inbox)

        let applicationObject = skrepka_as_application(application)
        controller.onShutDown = {
            g_application_release(applicationObject)
        }
        GtkSignal.onCloseRequest(UnsafeMutableRawPointer(window)) { [weak self] in
            self?.closing(onClosed)
            return false
        }
    }

    func present() {
        gtk_window_present(window)
    }

    /// Held until the link has closed a pairing window it opened: the last
    /// window going away would otherwise end the process before that call.
    private func closing(_ onClosed: () -> Void) {
        g_application_hold(skrepka_as_application(application))
        onClosed()
        controller.close()
    }
}
