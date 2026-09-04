import ClippyCore
import Foundation
import ServiceManagement
import os

/// Launch at login, via `SMAppService.mainApp`.
///
/// No helper bundle and no Info.plist key are needed for a plain app. launchd
/// refuses apps in temporary locations, so this only works once Clippy lives
/// somewhere durable such as `/Applications`.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
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
            ClippyLog.permissions.error("Login item change failed: \(error.localizedDescription)")
            if SMAppService.mainApp.status == .notFound {
                return
                    "Move Clippy to your Applications folder first — macOS will not launch an app at login from a temporary location."
            }
            return
                "Could not \(enabled ? "enable" : "disable") launch at login. \(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
