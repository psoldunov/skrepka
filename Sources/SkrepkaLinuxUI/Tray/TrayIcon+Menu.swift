extension TrayIcon {
    func handleMenuMethod(
        _ name: String,
        parameters: DBusValue,
        invocation: DBusInvocation
    ) {
        switch name {
        case "GetLayout": returnLayout(parameters, invocation: invocation)
        case "GetGroupProperties": returnGroupProperties(parameters, invocation: invocation)
        case "GetProperty": returnProperty(parameters, invocation: invocation)
        case "Event":
            handleEvent(parameters)
            invocation.returnValue()
        case "EventGroup":
            let errors = handleEventGroup(parameters).map(DBusValue.int32)
            invocation.returnValue(.tuple([.array(elementSignature: "i", values: errors)]))
        case "AboutToShow": invocation.returnValue(.tuple([.boolean(false)]))
        case "AboutToShowGroup": returnAboutToShowGroup(parameters, invocation: invocation)
        default:
            invocation.returnError(
                name: "org.freedesktop.DBus.Error.UnknownMethod",
                message: "Unknown dbusmenu method \(name)"
            )
        }
    }

    private func returnLayout(_ parameters: DBusValue, invocation: DBusInvocation) {
        let values = parameters.children ?? []
        let parent = values.first?.int32Value ?? 0
        let names = values.dropFirst(2).first?.children?.compactMap(\.stringValue) ?? []
        guard let layout = menu.layout(for: .init(rawValue: parent), names: names) else {
            invocation.returnError(
                name: "com.canonical.dbusmenu.Error.InvalidMenu",
                message: "No menu item \(parent)"
            )
            return
        }
        invocation.returnValue(.tuple([.uint32(revision), layout]))
    }

    private func returnGroupProperties(_ parameters: DBusValue, invocation: DBusInvocation) {
        let values = parameters.children ?? []
        let requested = values.first?.children?.compactMap(\.int32Value) ?? []
        let identifiers = requested.isEmpty ? menu.allIDs.map(\.rawValue) : requested
        let names = values.dropFirst().first?.children?.compactMap(\.stringValue) ?? []
        let properties = identifiers.compactMap { identifier -> DBusValue? in
            guard let values = menu.properties(for: .init(rawValue: identifier), names: names) else {
                return nil
            }
            return .tuple([.int32(identifier), .dictionary(values)])
        }
        invocation.returnValue(
            .tuple([
                .array(elementSignature: "(ia{sv})", values: properties)
            ]))
    }

    private func returnProperty(_ parameters: DBusValue, invocation: DBusInvocation) {
        let values = parameters.children ?? []
        guard
            let identifier = values.first?.int32Value,
            let name = values.dropFirst().first?.stringValue,
            let value = menu.properties(for: .init(rawValue: identifier))?[name]
        else {
            invocation.returnError(
                name: "com.canonical.dbusmenu.Error.InvalidMenu",
                message: "Unknown menu property"
            )
            return
        }
        invocation.returnValue(.tuple([.variant(value)]))
    }

    private func handleEvent(_ parameters: DBusValue) {
        let values = parameters.children ?? []
        guard
            values.dropFirst().first?.stringValue == "clicked",
            let identifier = values.first?.int32Value,
            menu.items.contains(where: { $0.id.rawValue == identifier })
        else { return }
        onMenuItem?(.init(rawValue: identifier))
    }

    private func handleEventGroup(_ parameters: DBusValue) -> [Int32] {
        guard let events = parameters.children?.first?.children else { return [] }
        var errors: [Int32] = []
        for event in events {
            let fields = event.children ?? []
            guard let identifier = fields.first?.int32Value else { continue }
            if menu.items.contains(where: { $0.id.rawValue == identifier }) {
                handleEvent(.tuple(fields))
            } else {
                errors.append(identifier)
            }
        }
        return errors
    }

    private func returnAboutToShowGroup(
        _ parameters: DBusValue, invocation: DBusInvocation
    ) {
        let requested = parameters.children?.first?.children?.compactMap(\.int32Value) ?? []
        let valid = Set(menu.allIDs.map(\.rawValue))
        let errors = requested.filter { !valid.contains($0) }.map(DBusValue.int32)
        invocation.returnValue(
            .tuple([
                .array(elementSignature: "i", values: []),
                .array(elementSignature: "i", values: errors),
            ]))
    }
}
