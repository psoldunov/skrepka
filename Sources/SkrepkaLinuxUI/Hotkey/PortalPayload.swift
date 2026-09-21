import Foundation

struct PortalResponse: Sendable, Equatable {
    let code: UInt32
    let results: [String: DBusValue]

    static func parse(_ value: DBusValue) -> PortalResponse? {
        guard
            let children = value.children,
            let code = children.first?.uint32Value,
            let results = children.dropFirst().first?.dictionaryValue
        else { return nil }
        return PortalResponse(code: code, results: results)
    }
}

struct PortalActivation: Sendable, Equatable {
    let session: String
    let shortcutID: String
    let activationToken: String?

    static func parse(_ value: DBusValue) -> PortalActivation? {
        guard
            let children = value.children,
            children.count == 4,
            let session = children[0].stringValue,
            let shortcutID = children[1].stringValue,
            case .uint64 = children[2],
            let options = children[3].dictionaryValue
        else { return nil }
        return PortalActivation(
            session: session,
            shortcutID: shortcutID,
            activationToken: options["activation_token"]?.stringValue
        )
    }
}

struct PortalShortcut: Sendable, Equatable {
    let identifier: String
    let triggerDescription: String?

    static func parseList(_ value: DBusValue?) -> [PortalShortcut] {
        guard let values = value?.children else { return [] }
        return values.compactMap { shortcut in
            guard
                let fields = shortcut.children,
                let identifier = fields.first?.stringValue,
                let properties = fields.dropFirst().first?.dictionaryValue
            else { return nil }
            return PortalShortcut(
                identifier: identifier,
                triggerDescription: properties["trigger_description"]?.stringValue
            )
        }
    }
}

enum GlobalShortcutTrigger {
    // XDG Shortcuts 0.1: XKB modifier names and keysym identifiers joined by +.
    static let showPicker = "LOGO+SHIFT+v"
}

enum PortalRequestPath {
    static func make(uniqueName: String, token: String) -> String {
        let sender = uniqueName.dropFirst().replacingOccurrences(of: ".", with: "_")
        return "/org/freedesktop/portal/desktop/request/\(sender)/\(token)"
    }
}
