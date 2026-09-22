import Foundation
import SkrepkaSync

/// How a settings pane names a file-size limit — "Off", "5 MB" — on both
/// platforms, so the Mac's menu and the Linux dropdown read the same.
public enum FileSyncLimitLabel {
    /// What a limit of `bytes` is called. Whole megabytes print whole; a
    /// value that is not one — only a hand edit produces it — prints to one
    /// decimal place, so it is never rounded into a choice it is not.
    public static func text(for bytes: Int) -> String {
        guard bytes > 0 else { return "Off" }
        let megabyte = FileSyncLimit.megabyte
        if bytes.isMultiple(of: megabyte) { return "\(bytes / megabyte) MB" }
        return String(format: "%.1f MB", Double(bytes) / Double(megabyte))
    }

    /// The choices a pane offers, with `current` added in order when it is not
    /// one of them — so a menu always has a row for the value it shows.
    public static func choices(including current: Int) -> [Int] {
        let choices = FileSyncLimit.choices
        guard !choices.contains(current) else { return choices }
        return (choices + [current]).sorted()
    }
}
