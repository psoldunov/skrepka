import Foundation

/// Client for the xdg-desktop-portal GlobalShortcuts interface.
///
/// ## A bus connection of its own
///
/// An unsandboxed app tells the portal who it is with
/// `org.freedesktop.host.portal.Registry.Register`, and the portal accepts
/// that only as the first thing it hears from the caller's bus name. The first
/// portal call of any kind makes the portal look the caller up and file it —
/// by its systemd unit, which for an app started from a terminal is the
/// terminal's — and from then on `Register` is refused with "Connection already
/// associated with an application ID". The process's shared session
/// connection is never first: GTK reads the Settings portal on it while it
/// opens the display, and the appearance monitor reads it again, both before
/// this client starts. So this client opens a private connection whose first
/// words to the portal are `Register`.
///
/// A `Register` that fails anyway is recorded in ``registration`` and stepped
/// over rather than treated as the end: the portal then names the app from
/// its systemd unit, which is this app's own ID whenever the desktop started
/// it from its launcher or autostart entry. The 0.2.1 client stopped at that
/// point, and the shortcut was never bound.
public final class GlobalShortcuts {
    public var onActivated: ((_ shortcutID: String, _ activationToken: String?) -> Void)?
    public var onStateChanged: ((GlobalShortcutsState) -> Void)?
    public private(set) var state: GlobalShortcutsState = .unavailable("not started")
    /// What the portal answered to `Register`, as one line for
    /// `skrepka-gui --status`.
    public private(set) var registration = "not attempted"

    static let portalName = "org.freedesktop.portal.Desktop"
    static let portalPath = "/org/freedesktop/portal/desktop"

    let applicationID: String
    var connection: DBusConnection?
    private var portalWatch: DBusNameWatch?
    var portalOwner: String?
    var session: String?
    var requests: [String: PortalRequest] = [:]
    var signals: [DBusSignalSubscription] = []

    public init(applicationID: String) {
        self.applicationID = applicationID
    }

    public func start() {
        guard connection == nil else { return }
        do {
            let connection = try DBusConnection.privateSession()
            self.connection = connection
            portalWatch = DBusNameWatch(
                connection: connection,
                name: Self.portalName,
                appeared: { [weak self] owner in self?.portalAppeared(owner) },
                vanished: { [weak self] in self?.portalVanished() }
            )
            activatePortal(on: connection)
        } catch {
            setState(.unavailable("no session bus connection: \(error)"))
        }
    }

    /// Asks the bus to start the portal if nothing has yet. Addressed to the
    /// bus itself, not the portal, so it does not spend `Register`'s turn.
    private func activatePortal(on connection: DBusConnection) {
        connection.call(
            destination: "org.freedesktop.DBus",
            path: "/org/freedesktop/DBus",
            interface: "org.freedesktop.DBus",
            method: "StartServiceByName",
            parameters: .tuple([.string(Self.portalName), .uint32(0)])
        ) { [weak self] result in
            guard let self, case .failure(let error) = result, portalOwner == nil else { return }
            setState(.unavailable("no desktop portal to start: \(error.description)"))
        }
    }

    private func portalAppeared(_ owner: String) {
        resetSession()
        portalOwner = owner
        setState(.connecting)
        guard let connection else { return }
        connection.call(
            destination: Self.portalName,
            path: Self.portalPath,
            interface: "org.freedesktop.host.portal.Registry",
            method: "Register",
            parameters: .tuple([.string(applicationID), .dictionary([:])])
        ) { [weak self] result in
            guard let self, portalOwner == owner else { return }
            registration = Self.describeRegistration(result, applicationID: applicationID)
            beginSession()
        }
    }

    private func portalVanished() {
        portalOwner = nil
        resetSession()
        setState(.unavailable("the desktop portal is not running"))
    }

    static func describeRegistration(
        _ result: Result<DBusValue, DBusError>, applicationID: String
    ) -> String {
        switch result {
        case .success:
            "registered as \(applicationID)"
        case .failure(let error) where error.isUnknownMember:
            "this portal predates app registration; it names the app from its launcher"
        case .failure(let error):
            "refused (\(error.description)); the portal names the app from its launcher"
        }
    }

    func resetSession() {
        session = nil
        signals.removeAll()
        requests.removeAll()
    }

    func setState(_ state: GlobalShortcutsState) {
        guard self.state != state else { return }
        self.state = state
        onStateChanged?(state)
    }
}
