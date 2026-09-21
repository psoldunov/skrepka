import Foundation

/// Launch at login, as the text of the user's autostart entry.
///
/// Turning it off writes `Hidden=true` into the entry rather than deleting it.
/// The freedesktop Autostart spec says an entry with `Hidden=true` MUST be
/// ignored, and that it is how a user disables one; and `install.sh` puts the
/// entry back on every upgrade, so a deleted one would quietly come back on,
/// where a hidden one is kept hidden (see its `install_desktop_entries`).
///
/// Pure: text in, text out. ``AutostartEntry`` reads and writes the file.
enum AutostartFile {
    /// The entry's file name — the app's ID, as `install.sh` installs it.
    static let fileName = "\(SkrepkaApplication.applicationID).desktop"

    private static let group = "[Desktop Entry]"
    /// GNOME's own on/off key for an autostart entry. Its settings write
    /// `false` here rather than `Hidden=true`, and GNOME skips an entry that
    /// says so.
    private static let gnomeKey = "X-GNOME-Autostart-enabled"

    /// Whether an entry starts the app at login: it exists, is not hidden, and
    /// GNOME's switch is not off.
    static func isEnabled(_ contents: String?) -> Bool {
        guard let contents else { return false }
        return !entryLines(contents).contains { line in
            value(of: line, for: "Hidden") == "true" || value(of: line, for: gnomeKey) == "false"
        }
    }

    /// The entry with launch at login on: every `Hidden=` line gone and
    /// GNOME's switch on, or a fresh entry when there was none.
    static func enabling(_ contents: String?, executable: String) -> String {
        guard let contents else { return template(executable: executable) }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.filter { key(of: $0) != "Hidden" }
            .map { key(of: $0) == gnomeKey ? "\(gnomeKey)=true" : $0 }
            .joined(separator: "\n")
    }

    /// The entry with launch at login off: `Hidden=true` as the first key of
    /// its `[Desktop Entry]` group, replacing any `Hidden=` already there.
    static func disabling(_ contents: String?, executable: String) -> String {
        let base = contents ?? template(executable: executable)
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { key(of: $0) == "Hidden" }
        if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == group }) {
            lines.insert("Hidden=true", at: header + 1)
        } else {
            lines.insert(contentsOf: [group, "Hidden=true"], at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// The entry `packaging/autostart/` ships, with `Exec=` pointing at this
    /// executable — for turning launch at login on where no entry exists.
    static func template(executable: String) -> String {
        """
        [Desktop Entry]
        Type=Application
        Name=Skrepka
        Comment=Clipboard history in the tray, and the picker on its shortcut
        Exec=\(execQuoted(executable)) --background
        Icon=\(SkrepkaApplication.applicationID)
        Terminal=false
        NoDisplay=true
        X-GNOME-Autostart-enabled=true

        """
    }

    /// A path as a Desktop Entry `Exec=` program: bare when it needs no
    /// quoting, otherwise double-quoted with `"`, `` ` ``, `$` and `\`
    /// escaped — the Desktop Entry spec's quoting rules.
    static func execQuoted(_ path: String) -> String {
        let reserved = Set(" \t\"'\\><~|&;$*?#()`")
        guard path.contains(where: { reserved.contains($0) }) else { return path }
        var quoted = "\""
        for character in path {
            if "\"`$\\".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }

    /// The lines of the `[Desktop Entry]` group, which is the only group
    /// whose `Hidden` key counts.
    private static func entryLines(_ contents: String) -> [String] {
        var inEntry = false
        var lines: [String] = []
        for line in contents.split(separator: "\n").map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inEntry = trimmed == group
            } else if inEntry {
                lines.append(trimmed)
            }
        }
        return lines
    }

    /// The trimmed value of a `key=value` line, when the line sets `key`.
    private static func value(of line: String, for key: String) -> String? {
        guard self.key(of: line) == key, let equals = line.firstIndex(of: "=") else { return nil }
        return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }

    /// The key of a `Key=Value` line, trimmed; nil for anything else.
    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    }
}
