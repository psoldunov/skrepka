import Foundation

/// The user's autostart entry on disk: `$XDG_CONFIG_HOME/autostart/`, or
/// `~/.config/autostart/` — the file ``AutostartFile`` decides the text of.
///
/// Read and written on the main loop's thread, synchronously. It is one small
/// file in the user's own config directory, read when the window opens and
/// written when a switch is flipped.
struct AutostartEntry {
    let file: URL
    /// The `skrepka-gui` a fresh entry starts.
    let executable: String

    /// The entry for this user and this executable.
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let configHome =
            environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let file = configHome.appendingPathComponent("autostart").appendingPathComponent(
            AutostartFile.fileName)
        let executable = Bundle.main.executableURL?.path ?? "skrepka-gui"
        return AutostartEntry(file: file, executable: executable)
    }

    var status: AutostartStatus {
        AutostartStatus(isEnabled: AutostartFile.isEnabled(contents()))
    }

    /// Turns launch at login on or off, and answers what it is now — with a
    /// sentence for the user when the file could not be written.
    func setEnabled(_ isEnabled: Bool) -> AutostartStatus {
        let current = contents()
        let next =
            isEnabled
            ? AutostartFile.enabling(current, executable: executable)
            : AutostartFile.disabling(current, executable: executable)
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try next.write(to: file, atomically: true, encoding: .utf8)
            return status
        } catch {
            let path = file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return AutostartStatus(
                isEnabled: AutostartFile.isEnabled(current),
                error: "Skrepka could not write \(path): \(error.localizedDescription)"
            )
        }
    }

    /// The entry's text, or nil when there is none. An unreadable file reads
    /// as none: launch at login shows off, and turning it on rewrites it.
    private func contents() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }
}
