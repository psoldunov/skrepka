import Foundation

/// Renders a ``DiagnosticsSnapshot`` as plain text the user can paste into a
/// bug report.
///
/// Pure and deterministic — the date formatter is fixed rather than locale
/// dependent, so the output is the same everywhere and the tests mean
/// something.
public enum DiagnosticsReport {
    public static func text(for snapshot: DiagnosticsSnapshot) -> String {
        var lines = [
            "Skrepka \(snapshot.appVersion)",
            // `operatingSystemVersionString` already begins "Version", so a
            // "macOS " prefix would read "macOS Version 26.6.2".
            "System: \(snapshot.systemVersion)",
            "",
            "Clipboard access: \(snapshot.pasteboardAccess.summary)",
            "Capturing: \(snapshot.isCaptureBlocked ? "blocked" : "yes")",
            "Last capture: \(lastCapture(snapshot.lastCapturedAt))",
            "Accessibility: \(snapshot.isAccessibilityTrusted ? "granted" : "not granted")",
            "Paste automatically: \(snapshot.pasteAutomatically ? "on" : "off")",
            "Launch at login: \(snapshot.loginItem.rawValue)",
        ]

        switch snapshot.storage {
        case .onDisk(let path):
            lines.append("Storage: \(path)")
        case .inMemory(let reason):
            lines.append("Storage: in memory only — \(reason)")
        }
        lines.append("Stored items: \(snapshot.itemCount)")

        if let problem = snapshot.primaryProblem {
            lines.append(contentsOf: ["", "Problem: \(problem.summary)"])
        }

        return lines.joined(separator: "\n")
    }

    /// ISO 8601 in UTC, so a report pasted from another machine is directly
    /// comparable with this one's logs.
    ///
    /// Plain `.iso8601` and not a configured builder: `.iso8601.timeZone(...)`
    /// returns a style carrying only the field it was handed, which rendered
    /// every timestamp as the bare string "Z".
    private static func lastCapture(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.iso8601)
    }
}
