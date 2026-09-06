import AppKit
import Foundation

/// Deep links into the System Settings privacy panes Skrepka depends on.
///
/// The anchors are not guessed. Both appear in the strings of
/// `/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex`,
/// which is the pane that answers `com.apple.preference.security` on macOS 26.
enum SystemSettingsLink {
    /// Privacy & Security → Accessibility.
    static let accessibility = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    /// Privacy & Security → Pasteboard, where the user allows or denies
    /// programmatic reads of the general pasteboard.
    ///
    /// An app that has never triggered the access alert is not listed there at
    /// all — `NSPasteboard.h` says so — so this can legitimately open a pane
    /// with no Skrepka row in it.
    static let pasteboard = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
    )

    /// Privacy & Security, for the Local Network list.
    ///
    /// The pane and not the row, deliberately. The two links above name an
    /// anchor because `SecurityPrivacyExtension.appex` carries one for each —
    /// and on macOS 26 it carries no `Privacy_LocalNetwork` to go with them,
    /// which was checked in its strings rather than assumed. An anchor that does
    /// not exist is not ignored gracefully, so this opens the pane the list is
    /// on and leaves the user one scroll from it.
    static let localNetwork = URL(
        string: "x-apple.systempreferences:com.apple.preference.security"
    )

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
