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
            "  sync.file-limit  \(fileLimit(document.fileSync.maximumBytes))",
            "",
            "PASTE",
            "  paste.automatic  \(paste(document.paste))",
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

    static func fileLimit(_ bytes: Int) -> String {
        guard bytes > 0 else { return "off — copied files reach other devices as their names" }
        return "\(megabytes(bytes)) — larger copies of files reach other devices as their names"
    }

    /// Whole megabytes as `32 MB`; a hand-edited value that is not one as
    /// `12.5 MB`, so it is never rounded into a choice it is not.
    static func megabytes(_ bytes: Int) -> String {
        let megabyte = 1024 * 1024
        if bytes.isMultiple(of: megabyte) { return "\(bytes / megabyte) MB" }
        return String(format: "%.1f MB", Double(bytes) / Double(megabyte))
    }

    static func paste(_ paste: SettingsDocument.Paste) -> String {
        paste.isAutomatic
            ? "on — choosing an entry in the picker pastes it into the window underneath"
            : "off — choosing an entry only copies it; paste with Ctrl+V"
    }
}
