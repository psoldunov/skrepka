import Foundation
import SkrepkaIPC
import SkrepkaLinuxPlatform

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
    public let pasteAutomatically: Bool
    public let isPasteEditable: Bool
    public let pasteSubtitle: String

    public init(
        shortcut: GlobalShortcutsState,
        autostart: AutostartStatus,
        preferences: PreferencesModel = PreferencesModel(),
        pasteMechanism: PasteMechanism = .copyOnly
    ) {
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
        pasteAutomatically =
            preferences.inFlight.reversed()
            .compactMap(\.pasteAutomatically).first
            ?? preferences.document?.paste.isAutomatic
            ?? true
        isPasteEditable = preferences.isEditable && (preferences.document?.version ?? 0) >= 5
        pasteSubtitle = "\(pasteMechanism.settingsDetail) Terminals may need Ctrl+Shift+V instead."
    }

    /// Where the shortcut is changed. The Global Shortcuts portal on Plasma
    /// 6.4 is version 1, which has no call to open a "change shortcut" dialog,
    /// so the most this window can do is say where the desktop keeps it.
    public static let shortcutFooter = """
        Your desktop owns this shortcut. Change it in its shortcut settings — on KDE \
        Plasma, System Settings → Shortcuts — where Skrepka is listed by name.
        """

    public static let pastingFooter = """
        Skrepka always puts the entry on the clipboard first. If automatic paste fails, \
        press Ctrl+V yourself; terminal emulators commonly use Ctrl+Shift+V.
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
