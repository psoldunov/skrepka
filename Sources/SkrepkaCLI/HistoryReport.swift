import Foundation
import SkrepkaIPC

/// `skrepka list`, rendered for a person.
///
/// The numbering is the point: the number in the left column is what
/// `skrepka copy` takes, so the two commands are one workflow rather than two.
/// It is one-based for the same reason ``ClipSelector/position(_:)`` is — it is
/// the number the person read off the screen.
public enum HistoryReport {
    /// The time zone is a parameter rather than `.current` read inside, so a
    /// test can render a fixed document into fixed text. Callers pass nothing
    /// and get the machine's own zone.
    public static func text(_ document: HistoryDocument, timeZone: TimeZone = .current) -> String {
        guard !document.clips.isEmpty else {
            return "No clipboard history yet."
        }
        var lines = document.clips.enumerated().map { index, clip in
            line(index: index + 1, clip: clip, timeZone: timeZone)
        }
        if document.clips.count < document.total {
            lines.append("")
            lines.append("Showing \(document.clips.count) of \(document.total).")
        }
        return lines.joined(separator: "\n")
    }

    private static func line(index: Int, clip: ClipDocument, timeZone: TimeZone) -> String {
        let number = String(index).leftPadded(to: 3)
        let pin = clip.isPinned ? "*" : " "
        let hash = String(clip.contentHash.prefix(8)).rightPadded(to: 8)
        let kind = clip.kind.rightPadded(to: 6)
        let when = Self.stamp(clip.createdAt, in: timeZone)
        let size = clip.byteCount.map(Self.humanSize).map { " (\($0))" } ?? ""
        let files = Self.filesNote(clip.filesStatus)
        return "\(number) \(pin) \(hash)  \(kind)  \(when)  \(clip.preview)\(size)\(files)"
    }

    /// The pickers' words for a file row from another device whose files have
    /// not arrived, in brackets at the end of the line. Spelled here rather
    /// than taken from SkrepkaCore, which this target deliberately does not
    /// link.
    static func filesNote(_ status: String?) -> String {
        switch status {
        case ClipDocument.FilesStatusName.notSynced: " [contents not synced]"
        case ClipDocument.FilesStatusName.pending: " [contents not synced yet]"
        case ClipDocument.FilesStatusName.overLimit: " [contents over the sync size limit]"
        default: ""
        }
    }

    /// ``ReportStamp``'s format, which the doctor report shares.
    static func stamp(_ date: Date, in timeZone: TimeZone) -> String {
        ReportStamp.text(date, in: timeZone)
    }

    /// Round numbers rather than exact ones. Nobody acts on the difference
    /// between 1.4 and 1.42 megabytes, and a stable width keeps the column
    /// readable.
    static func humanSize(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0
            ? "\(bytes) B"
            : String(format: "%.1f %@", value, units[unit])
    }
}
