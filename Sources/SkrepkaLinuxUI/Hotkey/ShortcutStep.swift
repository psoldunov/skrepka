/// What the portal session does next with its answer about `show-picker` —
/// the one decision it makes, kept apart from the bus so it can be tested
/// without a portal.
enum ShortcutStep: Equatable {
    /// Bound. The portal's description of the trigger.
    case bound(String)
    /// Ask the desktop to bind it.
    case bind
    /// Ask what is bound: the last answer said nothing either way.
    case list
    /// Not bound, and why.
    case unbound(String)

    static let noKey = "the desktop left it without a key — assign one in its shortcut settings"

    /// After `ListShortcuts`.
    ///
    /// - Parameter mayBind: false for the listing that confirms a bind, so a
    ///   desktop that accepts a bind and then lists nothing cannot send the
    ///   session round in a loop.
    static func afterListing(_ result: Result<PortalResponse, DBusError>, mayBind: Bool) -> ShortcutStep {
        guard case .success(let response) = result, response.code == 0 else {
            // A failed listing is not fatal while binding is still allowed:
            // binding afresh is what an empty list leads to anyway, and the
            // desktop keeps a trigger the user already chose.
            return mayBind ? .bind : .unbound(GlobalShortcuts.describe(result))
        }
        if let trigger = trigger(in: response) { return .bound(trigger) }
        return mayBind ? .bind : .unbound(noKey)
    }

    /// After `BindShortcuts`.
    ///
    /// xdg-desktop-portal-kde 6.4 answers a successful bind with empty
    /// results — the binding is made, and only a `ListShortcuts` afterwards
    /// says so — so an answer that names no shortcuts at all is a reason to
    /// list, not a refusal. 0.2.1 read it as one.
    static func afterBinding(_ result: Result<PortalResponse, DBusError>) -> ShortcutStep {
        guard case .success(let response) = result, response.code == 0 else {
            return .unbound(GlobalShortcuts.describe(result))
        }
        if let trigger = trigger(in: response) { return .bound(trigger) }
        let named = PortalShortcut.parseList(response.results["shortcuts"])
        return named.isEmpty ? .list : .unbound(noKey)
    }

    private static func trigger(in response: PortalResponse) -> String? {
        let shortcuts = PortalShortcut.parseList(response.results["shortcuts"])
        guard let shortcut = shortcuts.first(where: { $0.identifier == GlobalShortcuts.pickerShortcutID })
        else { return nil }
        return shortcut.triggerDescription ?? GlobalShortcutTrigger.showPicker
    }
}
