struct RemoteDesktopPortalPayload {
    static let keyboard: UInt32 = 1

    static func createOptions(request: String, session: String) -> DBusValue {
        .dictionary([
            "handle_token": .string(request),
            "session_handle_token": .string(session),
        ])
    }

    static func selectOptions(request: String, restoreToken: String?) -> DBusValue {
        var values: [String: DBusValue] = [
            "handle_token": .string(request),
            "types": .uint32(keyboard),
            "persist_mode": .uint32(2),
        ]
        if let restoreToken { values["restore_token"] = .string(restoreToken) }
        return .dictionary(values)
    }

    static func startOptions(request: String) -> DBusValue {
        .dictionary(["handle_token": .string(request)])
    }

    static func sessionHandle(from response: PortalResponse) -> String? {
        guard response.code == 0 else { return nil }
        return response.results["session_handle"]?.stringValue
    }

    static func startResult(from response: PortalResponse) -> StartResult? {
        guard response.code == 0,
            let devices = response.results["devices"]?.uint32Value,
            devices & keyboard != 0
        else { return nil }
        return StartResult(restoreToken: response.results["restore_token"]?.stringValue)
    }

    struct StartResult: Sendable, Equatable {
        let restoreToken: String?
    }
}
