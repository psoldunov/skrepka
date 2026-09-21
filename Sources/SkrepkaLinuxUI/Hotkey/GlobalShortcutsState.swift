/// Where the global shortcut stands, as the app reports it.
public enum GlobalShortcutsState: Sendable, Equatable {
    /// No session with the portal, and why — not started, no portal on this
    /// desktop, or the portal refused one.
    case unavailable(String)
    /// The portal is there and a session is being set up.
    case connecting
    /// A session exists but `show-picker` has no trigger, and why — the user
    /// dismissed the desktop's prompt, or the desktop refused the binding.
    case unbound(String)
    /// Bound. The portal's own description of the trigger, e.g. "Meta+Shift+V".
    case bound(String)

    /// One line for `skrepka-gui --status` and the journal.
    public var summary: String {
        switch self {
        case .unavailable(let reason): "unavailable — \(reason)"
        case .connecting: "connecting to the Global Shortcuts portal"
        case .unbound(let reason): "not bound — \(reason)"
        case .bound(let trigger): "bound to \(ShortcutKeyName.display(chord: trigger))"
        }
    }
}
