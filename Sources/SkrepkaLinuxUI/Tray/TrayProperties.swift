struct TrayProperties {
    let problem: String?
    let pixmaps: [TrayPixmap]

    var status: String { problem == nil ? "Active" : "NeedsAttention" }

    var tooltip: DBusValue {
        .tuple([
            .string("skrepka-tray"),
            pixmapArray,
            .string(problem == nil ? "Skrepka" : "Skrepka needs attention"),
            .string(problem ?? "Clipboard history"),
        ])
    }

    func value(named name: String) -> DBusValue? {
        switch name {
        case "Category": .string("ApplicationStatus")
        case "Id": .string("skrepka")
        case "Title": .string("Skrepka")
        case "Status": .string(status)
        case "WindowId": .uint32(0)
        case "IconName": .string("skrepka-tray")
        default: secondaryValue(named: name)
        }
    }

    private func secondaryValue(named name: String) -> DBusValue? {
        switch name {
        case "IconThemePath": .string("")
        case "IconPixmap": pixmapArray
        case "AttentionIconName": .string("skrepka-tray")
        case "ToolTip": tooltip
        case "ItemIsMenu": .boolean(false)
        case "Menu": .objectPath("/MenuBar")
        default: nil
        }
    }

    private var pixmapArray: DBusValue {
        .array(elementSignature: "(iiay)", values: pixmaps.map(\.dbusValue))
    }
}
