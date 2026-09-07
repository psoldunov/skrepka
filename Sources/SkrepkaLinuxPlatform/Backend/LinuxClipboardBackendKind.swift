import Foundation

/// Which ``SkrepkaCore/ClipboardSource`` conformance this session can use.
public enum LinuxClipboardBackendKind: String, Sendable, Hashable, CaseIterable {
    /// `ext_data_control_manager_v1`. The current protocol, and the one to
    /// prefer wherever it is advertised.
    case extDataControl
    /// `zwlr_data_control_manager_v1`. The wlroots protocol, whose own XML now
    /// describes itself as deprecated and not for production use — which is not
    /// the same as unexercised. Wayfire and river advertise only this, and so
    /// does every wlroots older than 0.19.
    case wlrDataControl
    /// Xlib plus XFIXES, over a real X11 server or over XWayland.
    case xFixes

    /// What the diagnostics report calls it.
    public var displayName: String {
        switch self {
        case .extDataControl: "Wayland (ext-data-control-v1)"
        case .wlrDataControl: "Wayland (wlr-data-control, deprecated)"
        case .xFixes: "X11 (XFIXES)"
        }
    }
}
