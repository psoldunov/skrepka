import Foundation

/// The user's autostart entry on disk: `$XDG_CONFIG_HOME/autostart/`, or
/// `~/.config/autostart/` — the file ``AutostartFile`` decides the text of —
/// read over the system entries in `$XDG_CONFIG_DIRS/autostart/`.
///
/// `install.sh` writes the user's entry. A `.deb`, an `.rpm` or a NixOS system
/// installs a system one instead, and the freedesktop Autostart spec has the
/// user's directory override those: an entry there with the same name wins,
/// and one saying `Hidden=true` is how a user turns a system entry off. So the
/// switch reads whichever entry wins, and writes only the user's.
///
/// Read and written on the main loop's thread, synchronously. It is one small
/// file in the user's own config directory, read when the window opens and
/// written when a switch is flipped.
struct AutostartEntry {
    let file: URL
    /// The same file name in each system directory, most important first.
    let systemFiles: [URL]
    /// The `skrepka-gui` a fresh entry starts.
    let executable: String

    init(file: URL, systemFiles: [URL] = [], executable: String) {
        self.file = file
        self.systemFiles = systemFiles
        self.executable = executable
    }

    /// The entry for this user and this executable.
    ///
    /// `SKREPKA_GUI_EXECUTABLE` names the command a fresh entry runs when the
    /// running binary's own path is the wrong one to write down: a Nix build
    /// runs from a store path that garbage collection deletes, so its wrapper
    /// sets it to `skrepka-gui`.
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let configHome =
            environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        let executable =
            environment["SKREPKA_GUI_EXECUTABLE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? Bundle.main.executableURL?.path ?? "skrepka-gui"
        return AutostartEntry(
            file: autostartFile(in: configHome),
            systemFiles: systemConfigDirectories(environment).map(autostartFile(in:)),
            executable: executable)
    }

    var status: AutostartStatus {
        AutostartStatus(isEnabled: AutostartFile.isEnabled(effectiveContents()))
    }

    /// Turns launch at login on or off, and answers what it is now — with a
    /// sentence for the user when the file could not be written.
    ///
    /// Turning on an entry that is already on writes nothing, so a system
    /// entry is not copied into the user's directory, where it would stop
    /// following the package's own updates.
    func setEnabled(_ isEnabled: Bool) -> AutostartStatus {
        let current = effectiveContents()
        if isEnabled && AutostartFile.isEnabled(current) {
            return status
        }
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

    /// The text of the entry that decides: the user's when there is one,
    /// otherwise the first system directory's that has one, otherwise nil.
    private func effectiveContents() -> String? {
        ([file] + systemFiles).lazy.compactMap(Self.contents(of:)).first
    }

    /// A file's text, or nil when there is none. An unreadable file reads as
    /// none: launch at login shows off, and turning it on rewrites it.
    private static func contents(of file: URL) -> String? {
        // A missing or unreadable entry is the ordinary "no entry here" case.
        try? String(contentsOf: file, encoding: .utf8)
    }

    private static func autostartFile(in configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent("autostart").appendingPathComponent(AutostartFile.fileName)
    }

    /// `$XDG_CONFIG_DIRS`, most important first, keeping absolute paths only
    /// as the Base Directory spec asks; `/etc/xdg` when it names none.
    private static func systemConfigDirectories(_ environment: [String: String]) -> [URL] {
        let named = (environment["XDG_CONFIG_DIRS"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { $0.hasPrefix("/") }
        return (named.isEmpty ? ["/etc/xdg"] : named).map { URL(fileURLWithPath: $0) }
    }
}
