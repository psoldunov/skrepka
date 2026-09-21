import Foundation

/// The input-injection surface the live desktop offers.
public enum PasteMechanism: String, Sendable, Hashable {
    case xTest
    case virtualKeyboard
    case remoteDesktopPortal
    case copyOnly

    public static let virtualKeyboardGlobal = "zwp_virtual_keyboard_manager_v1"

    public static func decide(
        waylandGlobals: [String],
        waylandConnected: Bool,
        x11Connected: Bool
    ) -> PasteMechanism {
        if waylandGlobals.contains(virtualKeyboardGlobal) { return .virtualKeyboard }
        if waylandConnected { return .remoteDesktopPortal }
        if x11Connected { return .xTest }
        return .copyOnly
    }

    public var summary: String {
        switch self {
        case .xTest: "XTest (X11)"
        case .virtualKeyboard: "Wayland virtual keyboard"
        case .remoteDesktopPortal: "Remote Desktop portal"
        case .copyOnly: "copy only"
        }
    }

    public var settingsDetail: String {
        switch self {
        case .xTest:
            "This X11 session uses XTest. No desktop prompt is expected."
        case .virtualKeyboard:
            "This compositor allows a Wayland virtual keyboard. No desktop prompt is expected."
        case .remoteDesktopPortal:
            "Your desktop will ask once for permission to control the keyboard."
        case .copyOnly:
            "No input-injection service is available; use Ctrl+V after choosing an entry."
        }
    }

    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PasteMechanism {
        let waylandName = environment["WAYLAND_DISPLAY"]
        let globals = waylandName.map { WaylandGlobals.enumerate(displayName: $0) } ?? []
        let waylandConnected = waylandName != nil && !globals.isEmpty
        let x11Connected = environment["DISPLAY"].map(XDisplayProbe.canConnect) ?? false
        return decide(
            waylandGlobals: globals,
            waylandConnected: waylandConnected,
            x11Connected: x11Connected
        )
    }
}
