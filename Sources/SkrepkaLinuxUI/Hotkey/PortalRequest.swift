final class PortalRequest {
    typealias Completion = (Result<PortalResponse, DBusError>) -> Void

    let token: String
    private var subscription: DBusSignalSubscription?
    private var finished = false
    private let completion: Completion
    private let remove: (String) -> Void

    init(
        connection: DBusConnection,
        token: String,
        requestPath: String,
        method: String,
        parameters: DBusValue,
        completion: @escaping Completion,
        remove: @escaping (String) -> Void
    ) {
        self.token = token
        self.completion = completion
        self.remove = remove
        subscription = DBusSignalSubscription(
            connection: connection,
            sender: "org.freedesktop.portal.Desktop",
            interface: "org.freedesktop.portal.Request",
            member: "Response",
            path: requestPath
        ) { [weak self] _, value in
            self?.receive(value)
        }
        connection.call(
            destination: "org.freedesktop.portal.Desktop",
            path: "/org/freedesktop/portal/desktop",
            interface: "org.freedesktop.portal.GlobalShortcuts",
            method: method,
            parameters: parameters
        ) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.finish(.failure(error))
        }
    }

    private func receive(_ value: DBusValue) {
        guard let response = PortalResponse.parse(value) else {
            finish(.failure(DBusError(name: nil, message: "invalid portal Response payload")))
            return
        }
        finish(.success(response))
    }

    private func finish(_ result: Result<PortalResponse, DBusError>) {
        guard !finished else { return }
        finished = true
        subscription?.cancel()
        subscription = nil
        completion(result)
        remove(token)
    }
}
