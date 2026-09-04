import AppKit
import Foundation

/// Deep links into the System Settings privacy panes Clippy depends on.
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
    /// with no Clippy row in it.
    static let pasteboard = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard"
    )

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
