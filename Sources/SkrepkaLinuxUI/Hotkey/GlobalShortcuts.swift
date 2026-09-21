import Foundation

/// Client for the xdg-desktop-portal GlobalShortcuts interface.
public final class GlobalShortcuts {
    public var onActivated: ((_ shortcutID: String, _ activationToken: String?) -> Void)?
    public var onStateChanged: ((GlobalShortcutsState) -> Void)?
    public private(set) var state: GlobalShortcutsState = .unavailable("not started")

    private let applicationID: String
    private var connection: DBusConnection?
    private var portalWatch: DBusNameWatch?
    private var portalOwner: String?
    private var session: String?
    private var requests: [String: PortalRequest] = [:]
    private var signals: [DBusSignalSubscription] = []

    public init(applicationID: String) {
        self.applicationID = applicationID
    }

    public func start() {
        guard connection == nil else { return }
        do {
            let connection = try DBusConnection()
            self.connection = connection
            portalWatch = DBusNameWatch(
                connection: connection,
                name: "org.freedesktop.portal.Desktop",
                appeared: { [weak self] owner in self?.portalAppeared(owner) },
                vanished: { [weak self] in self?.portalVanished() }
            )
        } catch {
            setState(.unavailable(String(describing: error)))
        }
    }

    private func portalAppeared(_ owner: String) {
        resetSession()
        portalOwner = owner
        guard let connection else { return }
        connection.call(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.host.portal.Registry",
            method: "Register",
            parameters: .tuple([.string(applicationID), .dictionary([:])])
        ) { [weak self] result in
            guard let self, portalOwner == owner else { return }
            switch result {
            case .success: beginSession()
            case .failure(let error) where error.isUnknownMember: beginSession()
            case .failure(let error): setState(.unavailable(error.description))
            }
        }
    }

    private func portalVanished() {
        portalOwner = nil
        resetSession()
        setState(.unavailable("Global Shortcuts portal is not running"))
    }

}

extension GlobalShortcuts {
    private func beginSession() {
        setState(.unbound)
        let sessionToken = nextToken(prefix: "session")
        request(
            method: "CreateSession",
            values: [
                .dictionary([
                    "handle_token": .string(nextToken(prefix: "request")),
                    "session_handle_token": .string(sessionToken),
                ])
            ]
        ) { [weak self] result in
            guard let self,
                case .success(let response) = result,
                response.code == 0,
                let handle = response.results["session_handle"]?.stringValue
            else {
                self?.setState(.unavailable("Global Shortcuts session could not be created"))
                return
            }
            session = handle
            subscribeToSession(handle)
            listShortcuts(handle)
        }
    }

    private func subscribeToSession(_ handle: String) {
        guard let connection else { return }
        signals = [
            DBusSignalSubscription(
                connection: connection,
                sender: "org.freedesktop.portal.Desktop",
                interface: "org.freedesktop.portal.Session",
                member: "Closed",
                path: handle
            ) { [weak self] _, _ in self?.beginSession() },
            DBusSignalSubscription(
                connection: connection,
                sender: "org.freedesktop.portal.Desktop",
                interface: "org.freedesktop.portal.GlobalShortcuts",
                member: "Activated",
                path: "/org/freedesktop/portal/desktop"
            ) { [weak self] _, value in self?.receiveActivation(value) },
            DBusSignalSubscription(
                connection: connection,
                sender: "org.freedesktop.portal.Desktop",
                interface: "org.freedesktop.portal.GlobalShortcuts",
                member: "ShortcutsChanged",
                path: "/org/freedesktop/portal/desktop"
            ) { [weak self] _, value in self?.receiveShortcutsChanged(value) },
        ]
    }

    private func listShortcuts(_ handle: String) {
        request(
            method: "ListShortcuts",
            values: [.objectPath(handle), requestOptions()]
        ) { [weak self] result in
            guard let self, case .success(let response) = result, response.code == 0 else {
                self?.setState(.unbound)
                return
            }
            let shortcuts = PortalShortcut.parseList(response.results["shortcuts"])
            if let shortcut = shortcuts.first(where: { $0.identifier == "show-picker" }) {
                setState(.bound(shortcut.triggerDescription ?? GlobalShortcutTrigger.showPicker))
            } else {
                bindShortcut(handle)
            }
        }
    }

    private func bindShortcut(_ handle: String) {
        let shortcut = DBusValue.tuple([
            .string("show-picker"),
            .dictionary([
                "description": .string("Open the clipboard picker"),
                "preferred_trigger": .string(GlobalShortcutTrigger.showPicker),
            ]),
        ])
        request(
            method: "BindShortcuts",
            values: [
                .objectPath(handle),
                .array(elementSignature: "(sa{sv})", values: [shortcut]),
                .string(""),
                requestOptions(),
            ]
        ) { [weak self] result in
            guard let self, case .success(let response) = result, response.code == 0 else {
                self?.setState(.unbound)
                return
            }
            apply(shortcuts: PortalShortcut.parseList(response.results["shortcuts"]))
        }
    }

    private func receiveActivation(_ value: DBusValue) {
        guard let activation = PortalActivation.parse(value), activation.session == session else { return }
        onActivated?(activation.shortcutID, activation.activationToken)
    }

    private func receiveShortcutsChanged(_ value: DBusValue) {
        guard let values = value.children, values.first?.stringValue == session else { return }
        apply(shortcuts: PortalShortcut.parseList(values.dropFirst().first))
    }

    private func apply(shortcuts: [PortalShortcut]) {
        guard let shortcut = shortcuts.first(where: { $0.identifier == "show-picker" }) else {
            setState(.unbound)
            return
        }
        setState(.bound(shortcut.triggerDescription ?? GlobalShortcutTrigger.showPicker))
    }

    private func requestOptions() -> DBusValue {
        .dictionary(["handle_token": .string(nextToken(prefix: "request"))])
    }

    private func request(
        method: String,
        values: [DBusValue],
        completion: @escaping PortalRequest.Completion
    ) {
        guard let connection else { return }
        let token = handleToken(in: values) ?? nextToken(prefix: "request")
        let path = PortalRequestPath.make(uniqueName: connection.uniqueName, token: token)
        let request = PortalRequest(
            connection: connection,
            token: token,
            requestPath: path,
            method: method,
            parameters: .tuple(values),
            completion: completion,
            remove: { [weak self] token in self?.requests[token] = nil }
        )
        requests[token] = request
    }

    private func resetSession() {
        session = nil
        signals.removeAll()
        requests.removeAll()
    }

    private func setState(_ state: GlobalShortcutsState) {
        guard self.state != state else { return }
        self.state = state
        onStateChanged?(state)
    }

    private func nextToken(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private func handleToken(in values: [DBusValue]) -> String? {
        values.reversed().compactMap(\.dictionaryValue).first?["handle_token"]?.stringValue
    }
}
