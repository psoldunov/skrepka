public enum GlobalShortcutsState: Sendable, Equatable {
    case unavailable(String)
    case unbound
    case bound(String)
}
