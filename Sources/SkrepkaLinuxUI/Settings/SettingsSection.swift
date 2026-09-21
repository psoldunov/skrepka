/// The Settings window's sections, in the sidebar's order — the macOS
/// window's tabs, in the macOS window's order.
public enum SettingsSection: String, CaseIterable, Sendable {
    case general
    case history
    case privacy
    case sync
    case diagnostics

    public var title: String {
        switch self {
        case .general: "General"
        case .history: "History"
        case .privacy: "Privacy"
        case .sync: "Sync"
        case .diagnostics: "Status"
        }
    }

    /// A fallback chain, as ``PickerIconName`` gives one: a name Breeze has
    /// and a name Adwaita has, so the sidebar never draws a missing icon on
    /// either.
    var iconNames: [String] {
        switch self {
        case .general: ["preferences-system-symbolic", "emblem-system-symbolic", "configure-symbolic"]
        case .history: ["document-open-recent-symbolic", "view-history-symbolic", "edit-paste-symbolic"]
        case .privacy: ["security-high-symbolic", "channel-secure-symbolic", "changes-prevent-symbolic"]
        case .sync: ["emblem-synchronizing-symbolic", "view-refresh-symbolic", "network-wireless-symbolic"]
        case .diagnostics: ["dialog-information-symbolic", "help-about-symbolic", "help-browser-symbolic"]
        }
    }

    /// The section a name picks, as the demo's environment and a command
    /// line spell it; nil for anything else.
    public init?(named name: String) {
        let lowered = name.lowercased()
        // "status" is the pane's title, as on the Mac; "diagnostics" its name
        // in code. Either picks it.
        self.init(rawValue: lowered == "status" ? SettingsSection.diagnostics.rawValue : lowered)
    }
}
