import Foundation
import SkrepkaIPC

/// `skrepka doctor`, rendered for a person.
///
/// Problems first. Everything below them is the evidence somebody pastes into
/// an issue, and a report that buries "capture is not working" under twelve
/// lines of Wayland globals has told the user nothing they came for.
public enum DiagnosticsReport {
    public static func text(
        _ document: DiagnosticsDocument,
        timeZone: TimeZone = .current
    ) -> String {
        var lines = problems(document)
        lines += [
            "DAEMON",
            "  version      \(document.daemonVersion)",
            "  fingerprint  \(document.deviceFingerprint)",
            "",
        ]
        lines += session(document.session)
        lines += network(document.network)
        lines += storage(document.storage, timeZone: timeZone)
        return lines.joined(separator: "\n")
    }

    private static func problems(_ document: DiagnosticsDocument) -> [String] {
        guard !document.problems.isEmpty else {
            return ["Everything Skrepka checks is working.", ""]
        }
        return ["PROBLEMS"] + document.problems.map { "  - \($0)" } + [""]
    }

    private static func session(_ session: DiagnosticsDocument.Session) -> [String] {
        var lines = [
            "CLIPBOARD",
            "  backend      \(session.backendName)\(session.backend.map { " (\($0))" } ?? "")",
            "  desktop      \(session.desktop ?? "unknown")",
            "  wayland      \(session.waylandDisplay ?? "none")",
            "  x11          \(session.x11Display ?? "none")",
        ]
        if session.isXWaylandFallback {
            lines.append("  note         reading through XWayland — copies from Wayland apps are invisible")
        }
        if let problem = session.problem {
            lines.append("  \(session.isBlocking ? "blocked" : "note   ")      \(problem)")
        }
        if session.restarts > 0 {
            lines.append("  restarts     \(session.restarts) — the session went away and was picked up again")
        }
        if !session.waylandGlobals.isEmpty {
            lines.append("  globals      \(session.waylandGlobals.joined(separator: ", "))")
        }
        lines.append("")
        return lines
    }

    private static func network(_ network: DiagnosticsDocument.Network) -> [String] {
        var lines = [
            "NETWORK",
            "  responder    \(network.responder)\(network.isPublished ? ", published" : ", not published")",
            "  sync port    \(network.syncPort.map(String.init) ?? "sync is off")",
            "  peers        \(network.pairedCount) paired, \(network.sightedCount) in sight",
        ]
        if let problem = network.responderProblem {
            lines.append("  problem      \(problem)")
        }
        lines.append("")
        return lines
    }

    private static func storage(
        _ storage: DiagnosticsDocument.Storage,
        timeZone: TimeZone
    ) -> [String] {
        let captured =
            storage.lastCapturedAt.map { HistoryReport.stamp($0, in: timeZone) } ?? "nothing yet"
        return [
            "STORAGE",
            "  path         \(storage.path)",
            "  items        \(storage.itemCount)",
            "  last capture \(captured)",
            "  mode         \(storage.mode)",
        ]
    }
}
