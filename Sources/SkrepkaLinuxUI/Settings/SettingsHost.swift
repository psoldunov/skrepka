import CGtk4
import Foundation

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
    private let connect: DaemonLink.Connect
    /// The window on screen, if any.
    private var open: SettingsWindow?
    /// Windows that have closed and whose links are still winding up, by
    /// identity — each removes itself when its link reports it is done.
    private var closing: [ObjectIdentifier: SettingsWindow] = [:]

    init(application: UnsafeMutablePointer<GtkApplication>, connect: @escaping DaemonLink.Connect) {
        self.application = application
        self.connect = connect
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
        let inbox = try MainLoopInbox<SyncEvent>()
        let link = DaemonLink(connect: connect) { inbox.post($0) }
        let window = try SettingsWindow(application: application, link: link, inbox: inbox)
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
