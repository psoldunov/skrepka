import Foundation
import ServiceManagement
import SkrepkaCore
import os

/// Launch at login, via `SMAppService.mainApp`.
///
/// No helper bundle and no Info.plist key are needed for a plain app. launchd
/// refuses apps in temporary locations, so this only works once Skrepka lives
/// somewhere durable such as `/Applications`.
///
/// launchd owns this answer and Skrepka only ever asks. It is deliberately not
/// mirrored into ``Preferences``: it changes while the app is not running, and
/// `SMAppService.h` ships no notification for that — the header's own advice is
/// to check the status at launch, which is what ``RefreshOnActivation`` does for
/// the surfaces that show it.
enum LoginItem {
    /// The status, as one read.
    ///
    /// Everything asks through here rather than through a `status == .enabled`
    /// convenience per question: two such properties are two polls at two
    /// instants, and a caller that read both could show a switch and its notice
    /// disagreeing with each other.
    static var state: DiagnosticsSnapshot.LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        // SMAppServiceStatus is a plain NS_ENUM; an unknown value is reported
        // as "not enabled" rather than guessed at.
        @unknown default: .notRegistered
        }
    }

    /// - Returns: nil on success, or a user-facing message on failure.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            SkrepkaLog.permissions.error("Login item change failed: \(error.localizedDescription)")
            if SMAppService.mainApp.status == .notFound {
                return
                    "Move Skrepka to your Applications folder first — macOS will not launch an app at login from a temporary location."
            }
            return
                "Could not \(enabled ? "enable" : "disable") launch at login. \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
