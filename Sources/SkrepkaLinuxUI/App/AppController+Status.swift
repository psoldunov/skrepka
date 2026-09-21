import Foundation
import SkrepkaLinuxPlatform

// `skrepka-gui --status`: the parts of the app that can fail without anything
// on screen saying so, as the running instance sees them. Printed in the
// terminal that asked, which is the second process's — GApplication forwards
// the request and the answer.
extension AppController {
    func statusReport() -> String {
        let environment = ProcessInfo.processInfo.environment
        let desktop = environment["XDG_CURRENT_DESKTOP"] ?? "unknown desktop"
        let session = environment["XDG_SESSION_TYPE"] ?? "unknown session type"
        let lines = [
            "desktop:  \(desktop), \(session)",
            "picker:   \(pickerSummary)",
            "tray:     \(tray?.statusSummary ?? "could not be created — see the journal")",
            "shortcut: \(shortcuts.state.summary)",
            "paste:    \(paste.mechanism.summary)",
            "app ID:   \(shortcuts.registration)",
            "daemon:   \(daemonProblem ?? "no problem reported")",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private var pickerSummary: String {
        guard picker != nil else { return "could not be built — see the journal" }
        guard GtkSession.isLayerShellAvailable else {
            return "plain window (this session has no wlr-layer-shell)"
        }
        return "full-screen overlay (wlr-layer-shell v\(GtkSession.layerShellProtocolVersion))"
    }
}
