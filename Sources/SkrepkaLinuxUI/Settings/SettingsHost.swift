import CGtk4
import Foundation
import SkrepkaLinuxPlatform

/// The Settings window, opened from the tray, the picker's gear button and the
/// launcher's Settings action — as often as it is asked for.
///
/// At most one is on screen: asking again raises it. Closing it is not the end
/// of it, though. Its link to the daemon winds up after the window has gone —
/// refusing a pairing code nobody confirmed, closing a pairing window it
/// opened — and the window that owns the link has to outlive that. So a closed
/// window moves to ``closing`` until its link reports it has shut down, and a
/// request to open Settings meanwhile builds a fresh window with a fresh link
/// rather than waiting for the old one: the two talk to the daemon
/// independently, and the old one only ever says no to things.
final class SettingsHost {
    private let application: UnsafeMutablePointer<GtkApplication>
    private let connect: PreferencesJobs.Connect
    private let autostart: AutostartEntry
    private let pasteMechanism: PasteMechanism
    private let pasteAutomaticallyChanged: (Bool) -> Void
    /// The desktop's look, as last reported — a window built later is drawn in
    /// it too.
    private var appearance: AppearancePreference?
    /// The interface size in force, and why the last change of it could not
    /// be saved, if it could not.
    private var interfaceScale = InterfaceScaleStatus(scale: .standard)
    /// Keeps an interface size chosen in the General pane: saves it and
    /// redraws every window at it, Settings included, answering why it could
    /// not be saved, or nil. Wired by the app; with nothing wired, a choice
    /// redraws Settings alone and is not kept.
    var onInterfaceScale: ((InterfaceScale) -> String?)?
    /// The shortcut, as the portal session last reported it.
    private var shortcut: GlobalShortcutsState = .connecting
    /// The window on screen, if any.
    private var open: SettingsWindow?
    /// Windows that have closed and whose links are still winding up, by
    /// identity — each removes itself when its link reports it is done.
    private var closing: [ObjectIdentifier: SettingsWindow] = [:]

    init(
        application: UnsafeMutablePointer<GtkApplication>,
        autostart: AutostartEntry = .standard(),
        pasteMechanism: PasteMechanism = .copyOnly,
        pasteAutomaticallyChanged: @escaping (Bool) -> Void = { _ in },
        connect: @escaping PreferencesJobs.Connect
    ) {
        self.application = application
        self.autostart = autostart
        self.pasteMechanism = pasteMechanism
        self.pasteAutomaticallyChanged = pasteAutomaticallyChanged
        self.connect = connect
    }

    /// Restyles for the desktop's look: the stylesheet at once, and the
    /// window on screen, if any.
    func apply(_ appearance: AppearancePreference) {
        self.appearance = appearance
        SettingsStyle.apply(appearance, scale: interfaceScale.scale)
        open?.apply(appearance)
    }

    /// Redraws at `scale`: the stylesheet at once, which is every size the
    /// window on screen draws, and that window's own size, which would
    /// otherwise keep the old one and scroll the larger page inside it.
    func apply(_ scale: InterfaceScale) {
        interfaceScale = InterfaceScaleStatus(scale: scale)
        guard let appearance else { return }
        SettingsStyle.apply(appearance, scale: scale)
        open?.apply(scale)
    }

    private func chooseInterfaceScale(_ scale: InterfaceScale) -> InterfaceScaleStatus {
        guard let onInterfaceScale else {
            apply(scale)
            return interfaceScale
        }
        let error = onInterfaceScale(scale)
        interfaceScale = InterfaceScaleStatus(scale: scale, error: error)
        return interfaceScale
    }

    /// Passes on where the global shortcut stands, for the General pane.
    func setShortcut(_ state: GlobalShortcutsState) {
        shortcut = state
        open?.setShortcut(state)
    }

    /// Brings `section` forward in the window on screen.
    func select(_ section: SettingsSection) {
        open?.select(section)
    }

    /// Shows the window, building it if it is not open.
    ///
    /// - Parameter activationToken: An XDG activation token from whatever the
    ///   user clicked — the tray hands one over before it asks for Settings.
    ///   On Wayland it is what lets the window take focus rather than open
    ///   behind the app the user is in.
    func present(activationToken: String? = nil) {
        if let open {
            open.present(activationToken: activationToken)
            return
        }
        do {
            let window = try makeWindow()
            open = window
            window.present(activationToken: activationToken)
        } catch {
            FileHandle.standardError.write(Data("skrepka-gui: \(error)\n".utf8))
        }
    }

    /// Closes the window on screen, for an app that is quitting. Its link
    /// still winds up on its own.
    func closeAll() {
        open?.close()
    }

    /// Whether a closed window's link is still winding up — and holding the
    /// application open until it has.
    var isWindingUp: Bool {
        !closing.isEmpty
    }

    private func makeWindow() throws -> SettingsWindow {
        if appearance == nil { apply(.unknown) }
        let inbox = try MainLoopInbox<SyncEvent>()
        let connect = connect
        let link = DaemonLink(connect: { try await connect() }, report: { inbox.post($0) })
        let services = SettingsWindow.Services(
            link: link,
            inbox: inbox,
            connect: connect,
            autostart: autostart,
            shortcut: shortcut,
            pasteMechanism: pasteMechanism,
            pasteAutomaticallyChanged: pasteAutomaticallyChanged,
            interfaceScale: interfaceScale,
            chooseInterfaceScale: { [weak self] scale in
                self?.chooseInterfaceScale(scale) ?? InterfaceScaleStatus(scale: scale)
            }
        )
        let window = try SettingsWindow(application: application, services: services)
        if let appearance { window.apply(appearance) }
        let key = ObjectIdentifier(window)
        window.onClosed = { [weak self, weak window] in
            guard let self, let window else { return }
            if self.open === window { self.open = nil }
            self.closing[key] = window
        }
        window.onFinished = { [weak self] in
            self?.closing[key] = nil
        }
        Task(priority: .medium) { await link.start() }
        return window
    }
}
