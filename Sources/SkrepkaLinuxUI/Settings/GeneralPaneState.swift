import Foundation

/// The General pane, as the widgets draw it: the shortcut, pasting, and
/// launch at login.
///
/// Nothing here comes from the daemon. The shortcut is the app's own portal
/// session and launch at login is a file in `~/.config/autostart`, so this
/// pane works against a daemon of any version, or none.
public struct GeneralPaneState: Sendable, Hashable {
    /// The shortcut's keys, one keycap each — empty when there is no binding
    /// to show, and ``shortcutValue`` says why in a word.
    public let shortcutKeys: [String]
    public let shortcutValue: String
    public let shortcutSubtitle: String
    public let launchAtLogin: Bool
    /// What launch at login does — or, when the last change failed, why.
    public let launchSubtitle: String

    public init(shortcut: GlobalShortcutsState, autostart: AutostartStatus) {
        switch shortcut {
        case .bound(let trigger):
            shortcutKeys = Self.keys(trigger)
            shortcutValue = ""
            shortcutSubtitle = "Press this anywhere to open the clipboard picker."
        case .connecting:
            shortcutKeys = []
            shortcutValue = "Connecting…"
            shortcutSubtitle = "Asking the desktop for the shortcut."
        case .unbound(let reason):
            shortcutKeys = []
            shortcutValue = "Not set"
            shortcutSubtitle = SyncText.sentence(reason)
        case .unavailable(let reason):
            shortcutKeys = []
            shortcutValue = "Unavailable"
            shortcutSubtitle = SyncText.sentence(reason)
        }
        launchAtLogin = autostart.isEnabled
        launchSubtitle = autostart.error ?? "Skrepka starts in the tray, with no window."
    }

    /// Where the shortcut is changed. The Global Shortcuts portal on Plasma
    /// 6.4 is version 1, which has no call to open a "change shortcut" dialog,
    /// so the most this window can do is say where the desktop keeps it.
    public static let shortcutFooter = """
        Your desktop owns this shortcut. Change it in its shortcut settings — on KDE \
        Plasma, System Settings → Shortcuts — where Skrepka is listed by name.
        """

    public static let pastingTitle = "Choose an entry, then press Ctrl+V"
    public static let pastingSubtitle = "Skrepka copies what you choose; you paste it."
    public static let pastingFooter = """
        Linux gives an app no safe way to type into another one, so Skrepka never pastes \
        for you. The entry is on the clipboard the moment you choose it.
        """

    /// "Meta+Shift+V" as ["Meta", "Shift", "V"] — see ``ShortcutKeyName``. A
    /// trigger that is not a plain `+`-joined chord — a desktop's own phrasing
    /// — stays whole, one keycap, rather than being cut somewhere meaningless.
    static func keys(_ trigger: String) -> [String] {
        let trimmed = trigger.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard !trimmed.contains(" "), !trimmed.contains("<") else { return [trimmed] }
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: true)
            .map { ShortcutKeyName.display(String($0)) }
        // "Ctrl++" names the plus key itself; splitting eats it.
        if trimmed.hasSuffix("++") || trimmed == "+" {
            parts.append("+")
        }
        return parts
    }
}

/// Launch at login, as the General pane last found it.
public struct AutostartStatus: Sendable, Hashable {
    public let isEnabled: Bool
    /// Why the last change failed, for the user; nil when it did not.
    public let error: String?

    public init(isEnabled: Bool, error: String? = nil) {
        self.isEnabled = isEnabled
        self.error = error
    }
}
