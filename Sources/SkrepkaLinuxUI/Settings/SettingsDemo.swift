import CGtk4
import Foundation

/// Opens the Settings window against a daemon the caller supplies — for
/// `skrepka-settings-demo`, which draws every pane without `skrepkad` so it
/// can be screenshotted under a headless compositor.
///
/// Not part of the app: `skrepka-gui` builds its window through
/// ``AppController``. This is the smallest shell around the same
/// ``SettingsHost``.
public enum SettingsDemo {
    public struct Options: Sendable {
        public let section: SettingsSection
        public let appearance: AppearancePreference
        public let shortcut: GlobalShortcutsState
        /// Where the demo's launch-at-login switch writes, so it never
        /// touches the real `~/.config/autostart`.
        public let autostartFile: URL

        public init(
            section: SettingsSection,
            appearance: AppearancePreference,
            shortcut: GlobalShortcutsState,
            autostartFile: URL
        ) {
            self.section = section
            self.appearance = appearance
            self.shortcut = shortcut
            self.autostartFile = autostartFile
        }
    }

    /// Runs until the window closes, and answers the exit status.
    public static func run(
        options: Options,
        connect: @escaping @Sendable () async throws -> any SettingsDaemon
    ) -> Int32 {
        guard GtkSession.start(),
            let application = gtk_application_new(
                "dev.soldunov.Skrepka.SettingsDemo", G_APPLICATION_NON_UNIQUE)
        else { return 2 }
        let entry = AutostartEntry(file: options.autostartFile, executable: "/usr/bin/skrepka-gui")
        let host = SettingsHost(application: application, autostart: entry, connect: connect)
        GtkSignal.connect(UnsafeMutableRawPointer(application), "activate") {
            host.apply(options.appearance)
            host.setShortcut(options.shortcut)
            host.present()
            host.select(options.section)
        }
        let status = g_application_run(skrepka_as_application(application), 0, nil)
        g_object_unref(UnsafeMutableRawPointer(application))
        return status
    }
}
