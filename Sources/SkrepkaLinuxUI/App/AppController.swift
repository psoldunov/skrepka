import CGtk4
import Foundation
import SkrepkaIPC

/// Everything the running app does, joined in one place: the picker, the tray
/// icon, the global shortcut, the Settings window, and the daemon all of them
/// depend on.
///
/// Lives on GTK's main-loop thread, and so do the pieces it owns — the tray and
/// the shortcut talk to the bus through GDBus on this same loop. The one thing
/// that happens elsewhere, calls to the daemon, reports back through ``inbox``
/// as ``AppEvent`` values.
final class AppController {
    /// The shortcut the portal is asked to bind, and the ID its `Activated`
    /// signal names.
    static let pickerShortcutID = "show-picker"

    let application: UnsafeMutablePointer<GtkApplication>
    /// One connection for every window's calls to the daemon. A `BusSession`
    /// reconnects by itself when the daemon restarts, so it is made once.
    let session = BusSession(bus: .session)
    let settings: SettingsHost
    let picker: PickerController?
    let tray: TrayIcon?
    let shortcuts = GlobalShortcuts(applicationID: SkrepkaApplication.applicationID)
    let appearance = AppearanceMonitor()
    let inbox: MainLoopInbox<AppEvent>?
    private var watch: MainLoopWatch<AppEvent>?
    private var isHolding = false
    /// What is wrong with the daemon, as the tray's problem row says it; nil
    /// while it answers.
    var daemonProblem: String?
    /// The activation token the tray last handed over, spent on the next
    /// window it opens — how KWin on Wayland lets that window take focus.
    var activationToken: String?

    init(application: UnsafeMutablePointer<GtkApplication>) {
        self.application = application
        let session = session
        let connect: @Sendable () async throws -> DaemonProxy = {
            try await SkrepkaBus.proxy(on: session)
        }
        settings = SettingsHost(application: application) { try await connect() }
        picker = Self.makePicker { try await connect() }
        tray = Self.makeTray()
        // An inbox is an eventfd; failing to make one means the process is out
        // of descriptors. The app still opens its windows without it — it only
        // loses the daemon starter's report.
        inbox = try? MainLoopInbox()
    }

    /// Brings the app up: holds it open without a window, shows the tray,
    /// binds the shortcut, builds the picker hidden, and makes sure the daemon
    /// is running.
    func start() {
        // Held for as long as the app runs: it has a tray icon and a shortcut
        // and, most of the time, no window at all.
        g_application_hold(skrepka_as_application(application))
        isHolding = true
        if let inbox {
            watch = try? MainLoopWatch(inbox: inbox) { [weak self] event in
                self?.handle(event)
            }
        }
        wire()
        appearance.start()
        picker?.apply(appearance.current)
        picker?.start()
        tray?.start()
        shortcuts.start()
        ensureDaemon()
    }

    func perform(_ command: AppCommand) {
        switch command {
        case .showPicker:
            showPicker()
        case .togglePicker:
            togglePicker()
        case .openSettings:
            openSettings()
        case .background, .help, .quit:
            break
        }
    }

    /// Ends the app. The daemon is a separate service and keeps running.
    ///
    /// Not an immediate `g_application_quit` when a Settings window is open:
    /// its link still has to refuse a pairing code nobody confirmed and close a
    /// pairing window it opened, and the window holds the application until it
    /// has. Releasing this controller's own hold is what lets the app end then,
    /// and at once when nothing is winding up.
    func quit() {
        picker?.hide()
        watch?.cancel()
        watch = nil
        settings.closeAll()
        if isHolding {
            isHolding = false
            g_application_release(skrepka_as_application(application))
        }
        if !settings.isWindingUp {
            g_application_quit(skrepka_as_application(application))
        }
    }

    // MARK: - Windows

    func showPicker() {
        guard let picker else {
            openSettings()
            return
        }
        picker.show()
    }

    func togglePicker() {
        guard let picker else {
            openSettings()
            return
        }
        picker.toggle()
    }

    func openSettings() {
        picker?.hide()
        settings.present(activationToken: activationToken)
        activationToken = nil
    }

    // MARK: - Wiring

    private func wire() {
        picker?.onOpenSettings = { [weak self] in self?.openSettings() }
        appearance.onChange = { [weak self] preference in self?.picker?.apply(preference) }
        shortcuts.onActivated = { [weak self] shortcutID, _ in
            guard shortcutID == Self.pickerShortcutID else { return }
            self?.togglePicker()
        }
        tray?.onActivate = { [weak self] in self?.togglePicker() }
        tray?.onActivationToken = { [weak self] token in self?.activationToken = token }
        tray?.onMenuItem = { [weak self] id in
            guard let action = AppMenu.action(for: id) else { return }
            self?.perform(action)
        }
    }

    private static func makePicker(
        connect: @escaping @Sendable () async throws -> any PickerDaemon
    ) -> PickerController? {
        do {
            return try PickerController(connect: connect)
        } catch {
            let message = "skrepka-gui: the picker could not be built: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            return nil
        }
    }

    private static func makeTray() -> TrayIcon? {
        do {
            return try TrayIcon(menu: AppMenu.menu(problem: nil))
        } catch {
            FileHandle.standardError.write(Data("skrepka-gui: no tray icon: \(error)\n".utf8))
            return nil
        }
    }
}

/// What reaches the app's main loop from the bus.
enum AppEvent: Sendable {
    /// What the daemon starter found.
    case daemon(DaemonStarter.Outcome)
    /// What Clear History answered, or why it could not be asked.
    case cleared(Result<ActionDocument, ClearFailure>)
}

/// Why Clear History could not reach the daemon, as a sentence.
struct ClearFailure: Error, Sendable {
    let message: String
}
