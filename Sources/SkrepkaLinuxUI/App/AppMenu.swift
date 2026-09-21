/// The tray menu, decided without a bus in scope.
///
/// The same menu the macOS menu bar icon has — `StatusItemController` — in the
/// same order: a problem row when there is something wrong, the picker, Clear
/// History and Settings, and Quit. Built here as values so which item does
/// what is tested rather than read off a running tray.
enum AppMenu {
    /// What a menu item asks for. The raw value is the item's dbusmenu ID,
    /// which only has to be stable while the menu is exported; 0 is the root.
    enum Action: Int32, CaseIterable {
        case problem = 1
        case openPicker = 2
        case clearHistory = 3
        case settings = 4
        case quit = 5
    }

    /// Separators are items too in dbusmenu, and need IDs of their own.
    private static let problemSeparator = TrayMenu.ItemID(rawValue: 10)
    private static let pickerSeparator = TrayMenu.ItemID(rawValue: 11)
    private static let quitSeparator = TrayMenu.ItemID(rawValue: 12)

    /// The menu, with `problem` as its first row when there is one.
    ///
    /// The problem row and its separator are always present and only hidden,
    /// for the reason the macOS menu gives: a menu that grows a row at the top
    /// the first time something goes wrong changes shape under the pointer.
    static func menu(problem: String?) -> TrayMenu {
        TrayMenu(items: [
            item(.problem, problem ?? "", visible: problem != nil),
            TrayMenu.Item(id: problemSeparator, label: "", visible: problem != nil, separator: true),
            item(.openPicker, "Open Skrepka"),
            TrayMenu.Item(id: pickerSeparator, label: "", separator: true),
            item(.clearHistory, "Clear History…"),
            item(.settings, "Settings…"),
            TrayMenu.Item(id: quitSeparator, label: "", separator: true),
            item(.quit, "Quit Skrepka"),
        ])
    }

    /// The action behind an item ID, or nil for a separator or the root.
    static func action(for id: TrayMenu.ItemID) -> Action? {
        Action(rawValue: id.rawValue)
    }

    private static func item(_ action: Action, _ label: String, visible: Bool = true) -> TrayMenu.Item {
        TrayMenu.Item(id: TrayMenu.ItemID(rawValue: action.rawValue), label: label, visible: visible)
    }
}
