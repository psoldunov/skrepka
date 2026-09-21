import CGtk4
import Foundation

/// The application's `command-line` handler, and the controller it starts.
///
/// Every invocation lands here — this process's own, and each one a second
/// `skrepka-gui` forwards — and answers the exit status that invocation exits
/// with. The controller is built by the first command that needs it rather
/// than at `startup`, so `skrepka-gui --quit` run when nothing is running
/// starts no tray only to take it down again.
///
/// Lives on GTK's main-loop thread, reached from C through the signal's user
/// data like every other handler here.
final class AppShell {
    private let application: UnsafeMutablePointer<GtkApplication>
    private var controller: AppController?

    init(application: UnsafeMutablePointer<GtkApplication>) {
        self.application = application
    }

    /// Runs one invocation's command. Answers its exit status.
    func handle(arguments: [String], reply: (String, Bool) -> Void) -> Int32 {
        switch AppCommand.parse(arguments) {
        case .failure(let error):
            reply("skrepka-gui: \(error)\n\(AppCommand.usage)\n", true)
            return 2
        case .success(.help):
            reply(AppCommand.usage + "\n", false)
            return 0
        case .success(.quit):
            controller?.quit()
            controller = nil
            return 0
        case .success(let command):
            running().perform(command)
            return 0
        }
    }

    /// Called once `g_application_run` has returned.
    func finish() {
        controller?.quit()
        controller = nil
    }

    private func running() -> AppController {
        if let controller { return controller }
        let started = AppController(application: application)
        controller = started
        started.start()
        return started
    }

    // MARK: - The signal

    /// Connects `command-line`, one retain balanced by GLib's closure notify.
    static func connectCommandLine(of application: UnsafeMutablePointer<GtkApplication>, to shell: AppShell) {
        skrepka_connect(
            UnsafeMutableRawPointer(application),
            "command-line",
            unsafeBitCast(onCommandLine, to: GCallback.self),
            Unmanaged.passRetained(shell).toOpaque(),
            onReleased
        )
    }

    /// `gint (*)(GApplication *, GApplicationCommandLine *, gpointer)`.
    /// A literal closure for the reason `PaletteWindow+Signals.swift` gives.
    private static let onCommandLine: @convention(c) (gpointer?, gpointer?, gpointer?) -> gint = {
        commandLine($1, data: $2)
    }

    private static func commandLine(_ object: gpointer?, data: gpointer?) -> gint {
        guard let data, let object, let invocation = skrepka_as_command_line(object) else { return 1 }
        let shell = Unmanaged<AppShell>.fromOpaque(data).takeUnretainedValue()
        return shell.handle(arguments: arguments(of: invocation)) { text, isError in
            skrepka_command_line_print(invocation, text, isError ? 1 : 0)
        }
    }

    /// The invocation's arguments after the program name.
    private static func arguments(of invocation: UnsafeMutablePointer<GApplicationCommandLine>) -> [String] {
        var count: Int32 = 0
        guard let vector = g_application_command_line_get_arguments(invocation, &count) else { return [] }
        defer { g_strfreev(vector) }
        return (1..<max(1, Int(count))).compactMap { index in
            vector[index].map { String(cString: $0) }
        }
    }

    private static let onReleased: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<AppShell>.fromOpaque(data).release()
    }
}

/// Why the app could not start.
enum AppShellError: Error, CustomStringConvertible {
    /// No Wayland or X11 display to open, which is what an ssh session looks
    /// like.
    case noDisplay

    var description: String {
        """
        skrepka-gui could not open a display. Run it from a desktop session — your \
        history is also available from the skrepka command.
        """
    }
}
