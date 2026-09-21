import CGtk4
import Foundation

/// `skrepka-gui`, from launch to exit status: the tray icon, the picker its
/// shortcut opens, and the Settings window both lead to — one process.
///
/// ## One process, one instance
///
/// A `GtkApplication` with ``applicationID``, and that ID is load-bearing
/// three ways. It is the Wayland `app_id` a desktop matches to
/// `dev.soldunov.Skrepka.App.desktop` for the Settings window's name and icon.
/// It is the bus name GApplication claims to stay single-instance, so a second
/// launch — the launcher clicked again, a hand-bound shortcut running
/// `skrepka-gui --picker` — hands its arguments to the running app and exits
/// with the answer, instead of starting a second tray. And it is the app ID the
/// global-shortcuts portal files the shortcut under.
///
/// It cannot be `dev.soldunov.Skrepka`: the daemon owns that name on the same
/// bus, and a GApplication that claims it would either fail to register or
/// take the daemon's place.
///
/// ## Why the picker lives here and not in its own process
///
/// Phase 7's bar is a picker visible within 150 ms of the shortcut. A process
/// started per shortcut spends that budget connecting to the display and
/// building widgets; a process that is already running with the picker built
/// and hidden spends it drawing the rows it already has.
public enum SkrepkaApplication {
    /// Also the launcher entry's file name and the icon's name. The three must
    /// stay equal.
    public static let applicationID = "dev.soldunov.Skrepka.App"

    /// Runs the app until it quits, and returns the exit status.
    public static func run() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Settled here, before anything registers on the bus, for the two
        // answers that must not start the app: `--help` and a mistake. Handed
        // to a running instance they would be answered correctly; handed to no
        // instance they would start a tray only to print a line.
        switch AppCommand.parse(arguments) {
        case .success(.help):
            print(AppCommand.usage)
            return 0
        case .failure(let error):
            FileHandle.standardError.write(Data("skrepka-gui: \(error)\n\(AppCommand.usage)\n".utf8))
            return 2
        case .success:
            break
        }
        // WM_CLASS on X11 is GTK's program name, and a desktop matches it to
        // the launcher entry the way Wayland matches `app_id`. Set before GTK
        // starts, which is when it is read.
        g_set_prgname(applicationID)
        guard GtkSession.start() else {
            FileHandle.standardError.write(Data("\(AppShellError.noDisplay)\n".utf8))
            return 2
        }
        return runApplication()
    }

    private static func runApplication() -> Int32 {
        guard let application = gtk_application_new(applicationID, G_APPLICATION_HANDLES_COMMAND_LINE)
        else { return 1 }
        let shell = AppShell(application: application)
        AppShell.connectCommandLine(of: application, to: shell)
        // The real argv, so a second instance forwards exactly what it was
        // given; GApplication parses nothing of it, since no option is
        // registered with it.
        let status = g_application_run(
            skrepka_as_application(application), CommandLine.argc, CommandLine.unsafeArgv)
        shell.finish()
        g_object_unref(UnsafeMutableRawPointer(application))
        return status
    }
}
