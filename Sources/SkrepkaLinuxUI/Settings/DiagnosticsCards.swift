import Foundation
import SkrepkaIPC

/// The Diagnostics pane's four cards, built from a ``DiagnosticsDocument``
/// with `skrepka doctor`'s facts and wording, as rows a person reads.
enum DiagnosticsCards {
    typealias Card = DiagnosticsPaneState.Card
    typealias Row = DiagnosticsPaneState.Row

    static func clipboard(_ session: DiagnosticsDocument.Session) -> Card {
        let backend = session.backend.map { "\(session.backendName) (\($0))" } ?? session.backendName
        let rows = [
            Row("Reading through", backend),
            Row("Desktop", session.desktop ?? "Unknown"),
            Row("Wayland display", session.waylandDisplay ?? "None"),
            Row("X11 display", session.x11Display ?? "None"),
        ]
        var notes: [String] = []
        if let problem = session.problem {
            notes.append(SyncText.sentence(problem))
        }
        if session.isXWaylandFallback {
            notes.append("Reading through XWayland, so copies from Wayland apps are invisible.")
        }
        if session.restarts > 0 {
            let times = session.restarts == 1 ? "once" : "\(session.restarts) times"
            notes.append("The session went away and was picked up again \(times).")
        }
        return Card(title: "Clipboard", rows: rows, notes: notes)
    }

    static func network(_ network: DiagnosticsDocument.Network) -> Card {
        let responder = "\(network.responder), \(network.isPublished ? "published" : "not published")"
        let rows = [
            Row("Discovery", responder),
            Row("Sync port", network.syncPort.map(String.init) ?? "Sync is off"),
            Row("Devices", "\(network.pairedCount) paired, \(network.sightedCount) in sight"),
        ]
        let notes = network.responderProblem.map { [SyncText.sentence($0)] } ?? []
        return Card(title: "Network", rows: rows, notes: notes)
    }

    static func storage(_ storage: DiagnosticsDocument.Storage, timeZone: TimeZone) -> Card {
        let captured = storage.lastCapturedAt.map { ReportStamp.text($0, in: timeZone) } ?? "Nothing yet"
        let rows = [
            Row("History database", storage.path, isLiteral: true),
            Row("Stored entries", storage.itemCount.formatted()),
            Row("Last capture", captured),
            Row("File mode", storage.mode, isLiteral: true),
        ]
        return Card(title: "Storage", rows: rows, notes: [])
    }

    static func daemon(_ document: DiagnosticsDocument) -> Card {
        let rows = [
            Row("Version", document.daemonVersion),
            Row("Fingerprint", document.deviceFingerprint, isLiteral: true),
        ]
        return Card(title: "Daemon", rows: rows, notes: [])
    }
}
