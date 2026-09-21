/// The platform-independent menu tree exported through dbusmenu.
public struct TrayMenu: Sendable, Equatable {
    public struct ItemID: RawRepresentable, Hashable, Sendable, Equatable {
        public let rawValue: Int32

        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
    }

    public struct Item: Sendable, Equatable {
        public let id: ItemID
        public let label: String
        public let enabled: Bool
        public let visible: Bool
        public let separator: Bool

        public init(
            id: ItemID,
            label: String,
            enabled: Bool = true,
            visible: Bool = true,
            separator: Bool = false
        ) {
            self.id = id
            self.label = label
            self.enabled = enabled
            self.visible = visible
            self.separator = separator
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    var layout: DBusValue { layout(names: []) }

    var allIDs: [ItemID] {
        [ItemID(rawValue: 0)] + items.map(\.id)
    }

    func layout(names: [String]) -> DBusValue {
        .tuple([
            .int32(0),
            .dictionary(filtered(rootProperties, names: names)),
            .array(
                elementSignature: "v",
                values: items.map { .variant(layout(for: $0, names: names)) }
            ),
        ])
    }

    func layout(for id: ItemID, names: [String] = []) -> DBusValue? {
        guard id.rawValue != 0 else { return layout(names: names) }
        return items.first(where: { $0.id == id }).map { layout(for: $0, names: names) }
    }

    func properties(for id: ItemID, names: [String] = []) -> [String: DBusValue]? {
        if id.rawValue == 0 { return filtered(rootProperties, names: names) }
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return filtered(properties(for: item), names: names)
    }

    private var rootProperties: [String: DBusValue] {
        items.isEmpty ? [:] : ["children-display": .string("submenu")]
    }

    private func properties(for item: Item) -> [String: DBusValue] {
        item.separator
            ? ["type": .string("separator"), "visible": .boolean(item.visible)]
            : [
                "label": .string(item.label),
                "enabled": .boolean(item.enabled),
                "visible": .boolean(item.visible),
            ]
    }

    private func filtered(
        _ properties: [String: DBusValue], names: [String]
    ) -> [String: DBusValue] {
        guard !names.isEmpty else { return properties }
        return properties.filter { names.contains($0.key) }
    }

    private func layout(for item: Item, names: [String]) -> DBusValue {
        .tuple([
            .int32(item.id.rawValue),
            .dictionary(filtered(properties(for: item), names: names)),
            .array(elementSignature: "v", values: []),
        ])
    }
}
