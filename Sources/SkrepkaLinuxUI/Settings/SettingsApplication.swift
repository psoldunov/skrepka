import CGtk4
import Foundation
import SkrepkaIPC

/// `skrepka-settings`, from launch to exit status.
///
/// A `GtkApplication` rather than a bare main loop, for two things only it
/// gives: the application ID becomes the Wayland `app_id`, which is how a
/// desktop matches the window to `dev.soldunov.Skrepka.Settings.desktop` for
/// its name and icon; and a second launch — the launcher clicked twice —
/// raises the window already open instead of opening another, whose pairing
/// dialogs would race the first's.
public enum SettingsApplication {
    /// Also the desktop entry's file name. The two must stay equal.
    public static let applicationID = "dev.soldunov.Skrepka.Settings"

    /// Runs the window against the daemon on the session bus until it closes,
    /// and returns the exit status.
    public static func run() -> Int32 {
        let session = BusSession(bus: .session)
        return run { try await SkrepkaBus.proxy(on: session) }
    }

    /// Runs the window against whatever `connect` reaches: the daemon, or
    /// anything else that answers ``SyncDaemon``. The second is the seam for
    /// looking at the window with canned devices rather than a network of
    /// peers; no such stand-in is committed.
    static func run(connect: @escaping DaemonLink.Connect) -> Int32 {
        // Asked first, with the call that returns rather than aborts, so a
        // shell without a display gets a sentence instead of GTK's abort.
        guard GtkSession.start() else {
            FileHandle.standardError.write(Data("\(SettingsError.noDisplay)\n".utf8))
            return 2
        }
        SettingsStyle.install()
        // The window's copyable labels are in the focus chain, and a new
        // window focuses its first focusable widget — here, a label. Left on,
        // that would select the label's text the moment the window appears.
        GtkBuild.selectsLabelTextOnFocus(false)
        let inbox: MainLoopInbox<SyncEvent>
        do {
            inbox = try MainLoopInbox()
        } catch {
            FileHandle.standardError.write(Data("skrepka-settings: \(error)\n".utf8))
            return 1
        }
        guard let application = gtk_application_new(applicationID, G_APPLICATION_DEFAULT_FLAGS) else {
            return 1
        }
        let link = DaemonLink(connect: connect, report: { inbox.post($0) })
        let host = SettingsHost(application: application, link: link, inbox: inbox)
        GtkSignal.connect(UnsafeMutableRawPointer(application), "activate") {
            host.activate()
        }
        // No arguments passed on: the window takes none, and GApplication would
        // otherwise answer an unknown one with an error instead of a window.
        let status = g_application_run(skrepka_as_application(application), 0, nil)
        g_object_unref(UnsafeMutableRawPointer(application))
        return status
    }
}
