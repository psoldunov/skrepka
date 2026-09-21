import Foundation
import SkrepkaIPC

/// `skrepka config`, rendered for a person.
///
/// Each setting is printed beside the key `config set` changes it with, so the
/// output is its own instructions.
public enum SettingsReport {
    public static func text(_ document: SettingsDocument) -> String {
        let history = document.history
        var lines = [
            "RETENTION",
            "  retention.items  \(items(document.retention.maximumItems))",
            "  retention.days   \(days(document.retention.maximumAgeDays))",
            "",
            "SYNC",
            "  sync.enabled     \(sync(document.sync))",
            "",
            "HISTORY",
            "  entries          \(history.entries)",
            "  pinned           \(history.pinned)",
            "  pictures         \(history.images)",
            "",
            "ALWAYS PROTECTED",
        ]
        lines += document.protectedMarkers.map { "  \($0)" }
        lines += ["", "Change one with `skrepka config set <key> <value>`."]
        return lines.joined(separator: "\n")
    }

    static func items(_ limit: Int) -> String {
        switch limit {
        case 0: "unlimited — every unpinned entry is kept"
        case 1: "1 unpinned entry"
        default: "\(limit) unpinned entries"
        }
    }

    static func days(_ limit: Int) -> String {
        switch limit {
        case 0: "unlimited — entries never age out"
        case 1: "1 day"
        default: "\(limit) days"
        }
    }

    static func sync(_ sync: SettingsDocument.Sync) -> String {
        if sync.isLockedOff { return "off — skrepkad was started with --no-sync" }
        return sync.isEnabled ? "on" : "off"
    }
}
