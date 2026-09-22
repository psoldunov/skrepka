import Foundation

// The portal session: create it, list what is bound, bind `show-picker` if
// nothing is, and listen for the shortcut firing. Every request answers
// through an `org.freedesktop.portal.Request` object — see ``PortalRequest``.
extension GlobalShortcuts {
    static let pickerShortcutID = "show-picker"

    func beginSession() {
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
            guard let self else { return }
            guard case .success(let response) = result, response.code == 0,
                let handle = response.results["session_handle"]?.stringValue
            else {
                setState(.unavailable("the portal refused a session: \(Self.describe(result))"))
                return
            }
            session = handle
            subscribeToSession(handle)
            listShortcuts(handle, mayBind: true)
        }
    }

    private func subscribeToSession(_ handle: String) {
        guard let connection else { return }
        signals = [
            DBusSignalSubscription(
                connection: connection,
                sender: Self.portalName,
                interface: "org.freedesktop.portal.Session",
                member: "Closed",
                path: handle
            ) { [weak self] _, _ in self?.beginSession() },
            DBusSignalSubscription(
                connection: connection,
                sender: Self.portalName,
                interface: "org.freedesktop.portal.GlobalShortcuts",
                member: "Activated",
                path: Self.portalPath
            ) { [weak self] _, value in self?.receiveActivation(value) },
            DBusSignalSubscription(
                connection: connection,
                sender: Self.portalName,
                interface: "org.freedesktop.portal.GlobalShortcuts",
                member: "ShortcutsChanged",
                path: Self.portalPath
            ) { [weak self] _, value in self?.receiveShortcutsChanged(value) },
        ]
    }

    private func listShortcuts(_ handle: String, mayBind: Bool) {
        let options = requestOptions()
        request(method: "ListShortcuts", values: [.objectPath(handle), options]) { [weak self] result in
            self?.take(ShortcutStep.afterListing(result, mayBind: mayBind), handle: handle)
        }
    }

    private func take(_ step: ShortcutStep, handle: String) {
        switch step {
        case .bound(let trigger): setState(.bound(trigger))
        case .bind: bindShortcut(handle)
        case .list: listShortcuts(handle, mayBind: false)
        case .unbound(let reason): setState(.unbound(reason))
        }
    }

    private func bindShortcut(_ handle: String) {
        let shortcut = DBusValue.tuple([
            .string(Self.pickerShortcutID),
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
            self?.take(ShortcutStep.afterBinding(result), handle: handle)
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
        guard let shortcut = shortcuts.first(where: { $0.identifier == Self.pickerShortcutID }) else {
            setState(.unbound(ShortcutStep.noKey))
            return
        }
        setState(.bound(shortcut.triggerDescription ?? GlobalShortcutTrigger.showPicker))
    }

    /// A request's outcome in words, for the state and the journal.
    static func describe(_ result: Result<PortalResponse, DBusError>) -> String {
        switch result {
        case .failure(let error): error.description
        case .success(let response): PortalResponse.describe(code: response.code)
        }
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
            interface: "org.freedesktop.portal.GlobalShortcuts",
            method: method,
            parameters: .tuple(values),
            completion: completion,
            remove: { [weak self] token in self?.requests[token] = nil }
        )
        requests[token] = request
    }

    private func nextToken(prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private func handleToken(in values: [DBusValue]) -> String? {
        values.reversed().compactMap(\.dictionaryValue).first?["handle_token"]?.stringValue
    }
}
