import Foundation
import SkrepkaCore
import Testing

@testable import SkrepkaDaemon

/// Where the daemon keeps its files.
///
/// The rules are the XDG base directory specification's, and the reason they
/// are tested rather than assumed is that getting one wrong is invisible: a
/// daemon that writes to the wrong directory works perfectly until the user
/// looks for their history, or until a backup policy that covers
/// `$XDG_DATA_HOME` misses it.
@Suite("Daemon paths")
struct DaemonPathsTests {
    static let home = URL(filePath: "/home/tester", directoryHint: .isDirectory)

    @Test("XDG_DATA_HOME decides where the database and the key live")
    func honoursDataHome() {
        let environment = ["XDG_DATA_HOME": "/data"]
        #expect(
            SessionPaths.historyStoreURL(environment: environment, homeDirectory: Self.home).path
                == "/data/skrepka/skrepka.sqlite3")
        #expect(
            SessionPaths.deviceKeyURL(environment: environment, homeDirectory: Self.home).path
                == "/data/skrepka/device.key")
    }

    @Test("XDG_CONFIG_HOME decides where the settings live")
    func honoursConfigHome() {
        let environment = ["XDG_CONFIG_HOME": "/cfg"]
        #expect(
            SessionPaths.configDirectory(environment: environment, homeDirectory: Self.home).path
                == "/cfg/skrepka")
        #expect(
            SessionPaths.configURL(environment: environment, homeDirectory: Self.home).path
                == "/cfg/skrepka/config.json")
    }

    @Test("the defaults when neither variable is set")
    func fallsBackToTheSpecifiedDefaults() {
        // Deliberately not `~/.skrepka`. The specification puts user data under
        // `$XDG_DATA_HOME`, and a dotfile in `$HOME` is exactly what it exists
        // to stop.
        #expect(
            SessionPaths.historyStoreURL(environment: [:], homeDirectory: Self.home).path
                == "/home/tester/.local/share/skrepka/skrepka.sqlite3")
        #expect(
            SessionPaths.deviceKeyURL(environment: [:], homeDirectory: Self.home).path
                == "/home/tester/.local/share/skrepka/device.key")
        #expect(
            SessionPaths.configURL(environment: [:], homeDirectory: Self.home).path
                == "/home/tester/.config/skrepka/config.json")
    }

    /// The specification: "If an implementation encounters a relative path in
    /// any of these variables it should consider the path invalid and ignore
    /// it."
    ///
    /// Honouring a relative one would put the history wherever the daemon
    /// happened to be started from, which under systemd is `$HOME` and under a
    /// shell is anywhere.
    @Test("a relative or empty XDG value is treated as unset", arguments: ["", "relative/path", "."])
    func refusesRelativePaths(_ value: String) {
        let data = SessionPaths.historyStoreURL(
            environment: ["XDG_DATA_HOME": value], homeDirectory: Self.home)
        #expect(data.path == "/home/tester/.local/share/skrepka/skrepka.sqlite3")

        let config = SessionPaths.configURL(
            environment: ["XDG_CONFIG_HOME": value], homeDirectory: Self.home)
        #expect(config.path == "/home/tester/.config/skrepka/config.json")
    }

    @Test("--data-dir overrides the XDG rules for both files")
    func dataDirectoryOverrides() {
        var options = DaemonOptions()
        options.dataDirectory = URL(filePath: "/tmp/elsewhere", directoryHint: .isDirectory)
        #expect(
            options.storeURL(environment: ["XDG_DATA_HOME": "/data"]).path
                == "/tmp/elsewhere/skrepka.sqlite3")
        #expect(
            options.deviceKeyURL(environment: ["XDG_DATA_HOME": "/data"]).path
                == "/tmp/elsewhere/device.key")
    }
}
