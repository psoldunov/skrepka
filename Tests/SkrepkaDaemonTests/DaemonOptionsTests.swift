import Foundation
import Testing

@testable import SkrepkaDaemon

@Suite("Daemon options")
struct DaemonOptionsTests {
    @Test("the defaults")
    func defaults() throws {
        let options = try DaemonOptions.parse([])
        #expect(options.command == .run)
        #expect(options.syncEnabled)
        #expect(options.port == 0)
        #expect(options.displayName.isEmpty)
        #expect(options.logLevel == "info")
    }

    @Test("every flag")
    func parsesEveryFlag() throws {
        let options = try DaemonOptions.parse([
            "--name", "deck", "--no-sync", "--port", "7011",
            "--log-level", "debug", "--data-dir", "/tmp/d", "--config", "/tmp/c.json",
        ])
        #expect(options.displayName == "deck")
        #expect(options.syncEnabled == false)
        #expect(options.port == 7011)
        #expect(options.logLevel == "debug")
        #expect(options.dataDirectory?.path == "/tmp/d")
        #expect(options.configURL?.path == "/tmp/c.json")
    }

    @Test("help and version stop parsing", arguments: ["--help", "-h", "help"])
    func helpStopsParsing(_ flag: String) throws {
        #expect(try DaemonOptions.parse([flag]).command == .help)
        // Everything after is ignored rather than validated: someone asking for
        // help has already said they do not know the flags.
        #expect(try DaemonOptions.parse([flag, "--nonsense"]).command == .help)
    }

    @Test("--version stops parsing")
    func versionStopsParsing() throws {
        #expect(try DaemonOptions.parse(["--version"]).command == .version)
    }

    /// An unknown flag is an error rather than something ignored.
    ///
    /// A daemon that silently dropped `--no-sync` would advertise a machine its
    /// owner asked to keep off the network — which is the failure that makes
    /// this worth a test rather than a shrug.
    @Test("an unknown flag is refused")
    func refusesUnknownFlags() {
        #expect(throws: DaemonOptionsError.self) {
            _ = try DaemonOptions.parse(["--nosync"])
        }
        #expect(throws: DaemonOptionsError.self) {
            _ = try DaemonOptions.parse(["run"])
        }
    }

    @Test("a flag with no value is refused rather than defaulted")
    func refusesAMissingValue() {
        #expect(throws: DaemonOptionsError.self) {
            _ = try DaemonOptions.parse(["--name"])
        }
    }

    @Test("--port takes a port, or 0 for any free one", arguments: [0, 1, 7011, 65535])
    func acceptsEveryValidPort(_ port: Int) throws {
        #expect(try DaemonOptions.parse(["--port", String(port)]).port == port)
    }

    /// Two failures used to become the same silent default.
    ///
    /// `--port eighty` bound an ephemeral port that disagreed with whatever
    /// firewall rule the user had just written, and `--port 99999` reached
    /// NIO's `SocketAddress(ipAddress:port:)`, which narrows to `in_port_t`
    /// without checking and killed the daemon on a fatal error where a usage
    /// message belonged.
    @Test(
        "--port refuses anything that is not one",
        arguments: ["eighty", "99999", "65536", "-1", "80.5", "", "0x50"]
    )
    func refusesAnInvalidPort(_ value: String) {
        #expect(throws: DaemonOptionsError.self) {
            _ = try DaemonOptions.parse(["--port", value])
        }
    }

    @Test(
        "--log-level takes every level swift-log has",
        arguments: ["trace", "debug", "info", "notice", "warning", "error", "critical"]
    )
    func acceptsEveryLogLevel(_ level: String) throws {
        #expect(try DaemonOptions.parse(["--log-level", level]).logLevel == level)
    }

    /// A typo used to start the daemon at `info` with nothing said about it, so
    /// somebody debugging a sync failure got no trace and no hint their flag had
    /// done nothing.
    @Test("--log-level refuses a level it cannot spell", arguments: ["dbeug", "verbose", "INFO", ""])
    func refusesAnUnknownLogLevel(_ level: String) {
        #expect(throws: DaemonOptionsError.self) {
            _ = try DaemonOptions.parse(["--log-level", level])
        }
    }

    /// The usage block is the only place a user finds out what a flag takes, so
    /// a level swift-log accepts and the text omits is a level nobody uses.
    @Test("the usage text names every level")
    func usageNamesEveryLevel() {
        for level in ["trace", "debug", "info", "notice", "warning", "error", "critical"] {
            #expect(DaemonOptions.usage.contains(level))
        }
    }
}

@Suite("Device name")
struct DeviceNameTests {
    @Test("the domain is dropped, because an instance name is one DNS label")
    func dropsTheDomain() {
        #expect(DeviceName.shortened("desktop.example.internal") == "desktop")
        #expect(DeviceName.shortened("kavallaris") == "kavallaris")
    }

    @Test("a machine with no readable hostname still gets a name")
    func fallsBack() {
        // The identity is the certificate hash in the TXT record, so a machine
        // with no hostname should still appear on the network — under a dull
        // name rather than not at all.
        #expect(!DeviceName.fallback.isEmpty)
        #expect(!DeviceName.current(environment: [:]).isEmpty)
    }
}

@Suite("Daemon version")
struct DaemonVersionTests {
    /// Two version numbers that can disagree is exactly the shape of bug that
    /// ships, so this reads `Info.plist` from the repository and fails the
    /// build when they drift.
    ///
    /// `#filePath` is what makes that possible without a bundle: this file is
    /// at `Tests/SkrepkaDaemonTests/…`, so the repository root is two
    /// directories up, whatever the working directory of the test run is.
    @Test("matches the bundle version")
    func matchesTheBundleVersion() throws {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = root.appending(path: "Info.plist", directoryHint: .notDirectory)
        let text = try String(contentsOf: plist, encoding: .utf8)
        let marker = "<key>CFBundleShortVersionString</key>"
        let after = try #require(text.range(of: marker)).upperBound
        let open = try #require(text.range(of: "<string>", range: after..<text.endIndex)).upperBound
        let close = try #require(text.range(of: "</string>", range: open..<text.endIndex)).lowerBound
        #expect(String(text[open..<close]) == DaemonVersion.current)
    }
}
