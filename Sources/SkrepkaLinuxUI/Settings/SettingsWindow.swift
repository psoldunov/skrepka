import CGtk4
import SkrepkaLinuxPlatform

/// The Settings window: a sidebar of sections on the left and the chosen
/// section's page on the right, under a title bar drawn in the same colours.
///
/// An ordinary toplevel on purpose — not a layer-shell surface like the
/// picker. Settings is a window the user opens from the tray or the picker,
/// moves, and closes; it takes focus the way every other window does, and it
/// needs nothing a plain `xdg_toplevel` does not give it on every compositor.
///
/// Its title bar is GTK's own header bar, which GTK draws client-side on KDE
/// anyway; setting one is what lets the stylesheet colour it, so the window
/// does not wear Breeze's chrome over the picker's palette.
final class SettingsWindow {
    /// Called as the window closes. Its link is still winding up.
    var onClosed: (() -> Void)?
    /// Called once the link has shut down, after ``onClosed``. Nothing of this
    /// window is used after it.
    var onFinished: (() -> Void)?

    private let application: UnsafeMutablePointer<GtkApplication>
    private let window: UnsafeMutablePointer<GtkWindow>
    private let sidebar: SettingsSidebar
    private let content: SettingsContent
    private let controller: SyncController
    private let preferences: PreferencesController

    struct Services {
        let link: DaemonLink
        let inbox: MainLoopInbox<SyncEvent>
        let connect: PreferencesJobs.Connect
        let autostart: AutostartEntry
        let shortcut: GlobalShortcutsState
        let pasteMechanism: PasteMechanism
        let pasteAutomaticallyChanged: (Bool) -> Void
    }

    init(application: UnsafeMutablePointer<GtkApplication>, services: Services) throws {
        guard let widget = gtk_application_window_new(application),
            let window = skrepka_as_window(widget),
            let split = GtkBuild.box(vertical: false, spacing: 0)
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_add_css_class(widget, SettingsStyle.window)
        gtk_window_set_title(window, "Skrepka Settings")
        // Sized for the Steam Deck's 1280×800: the sidebar and a page of cards
        // side by side, with the panel's height to spare.
        gtk_window_set_default_size(window, 900, 660)
        try Self.installTitlebar(on: window)

        let sidebar = try SettingsSidebar()
        let content = try SettingsContent()
        GtkBuild.append(sidebar.widget, to: split)
        GtkBuild.append(content.stack, to: split)
        gtk_window_set_child(window, split)

        let dialog = try PairingDialog(parent: window)
        self.application = application
        self.window = window
        self.sidebar = sidebar
        self.content = content
        self.controller = try SyncController(
            pane: content.panes.sync,
            dialog: dialog,
            parent: window,
            link: services.link,
            inbox: services.inbox)
        self.preferences = try PreferencesController(panes: content.panes, parent: window, services: services)
        wire()
    }

    private func wire() {
        let applicationObject = skrepka_as_application(application)
        controller.onShutDown = { [weak self] in
            g_application_release(applicationObject)
            self?.onFinished?()
        }
        sidebar.onSelect = { [weak self] section in self?.show(section) }
        GtkSignal.onCloseRequest(UnsafeMutableRawPointer(window)) { [weak self] in
            self?.closing()
            return false
        }
    }

    private static func installTitlebar(on window: UnsafeMutablePointer<GtkWindow>) throws {
        guard let bar = gtk_header_bar_new(),
            let title = GtkBuild.label("Settings")
        else { throw SettingsError.widgetCreationFailed }
        gtk_widget_add_css_class(bar, SettingsStyle.titlebar)
        gtk_widget_add_css_class(title, "title")
        gtk_header_bar_set_title_widget(skrepka_as_header_bar(bar), title)
        gtk_window_set_titlebar(window, bar)
    }

    /// Raises the window, spending `activationToken` on it when there is one.
    func present(activationToken: String? = nil) {
        if let activationToken {
            gtk_window_set_startup_id(window, activationToken)
        }
        gtk_window_present(window)
    }

    /// Brings `section` forward, as a click on its sidebar row would.
    func select(_ section: SettingsSection) {
        sidebar.select(section)
    }

    /// Restyles for a dark or light desktop and its accent.
    func apply(_ appearance: AppearancePreference) {
        sidebar.apply(appearance)
    }

    func setShortcut(_ state: GlobalShortcutsState) {
        preferences.setShortcut(state)
    }

    /// Closes it as the title bar's button would, running the same close
    /// request.
    func close() {
        gtk_window_close(window)
    }

    private func show(_ section: SettingsSection) {
        content.show(section)
        switch section {
        case .history, .privacy, .sync: preferences.load()
        case .diagnostics: preferences.diagnose()
        case .general: break
        }
    }

    /// Held until the link has closed a pairing window it opened: a window
    /// going away must not end the process before that call goes out.
    private func closing() {
        g_application_hold(skrepka_as_application(application))
        onClosed?()
        preferences.close()
        controller.close()
    }
}
