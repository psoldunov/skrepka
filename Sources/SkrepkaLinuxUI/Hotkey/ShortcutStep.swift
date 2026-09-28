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

    /// The first step of every new session: bind, whatever is already bound.
    ///
    /// **Listing first is the bug this replaced.** From xdg-desktop-portal-kde
    /// 6.7.4, `GlobalShortcutsSession::loadActions` no longer registers the
    /// saved trigger with kglobalaccel when a session is created: `ListShortcuts`
    /// on a fresh session still reports it, but only `BindShortcuts`
    /// (`setActions`) hands it to KWin. A client that lists, sees `show-picker`
    /// and stops has a shortcut the portal reports as bound and KWin never
    /// delivers — every login after the first. Through 6.7.3, `loadActions`
    /// made that registration itself, so listing alone worked there.
    ///
    /// Binding a shortcut the portal already knows opens no dialog on KDE (it
    /// is "returning", not new) and keeps the trigger the user chose. Checked
    /// on a second login under Plasma 6.4.3 with portal-kde 6.4.3 — SteamOS
    /// 3.8, `scripts/kde-image.sh`: no dialog, `BindShortcuts` answered
    /// `Success` with Meta+Shift+V, and the keys opened the picker. GNOME's
    /// portal lists nothing until a bind in the same session anyway, so it was
    /// always binding there.
    static let opening: ShortcutStep = .bind

    /// After the `ListShortcuts` that confirms a bind. Never binds again, so a
    /// desktop that accepts a bind and then lists nothing cannot send the
    /// session round in a loop.
    static func afterListing(_ result: Result<PortalResponse, DBusError>) -> ShortcutStep {
        guard case .success(let response) = result, response.code == 0 else {
            return .unbound(GlobalShortcuts.describe(result))
        }
        if let trigger = trigger(in: response) { return .bound(trigger) }
        return .unbound(noKey)
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
