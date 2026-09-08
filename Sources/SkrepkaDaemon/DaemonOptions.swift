import Foundation
import Logging
import SkrepkaCore
import SkrepkaSync

/// How `skrepkad` was invoked, and where it keeps its files.
///
/// Hand-parsed rather than through `swift-argument-parser`, following
/// `ProbeOptions`: the daemon must build on Linux with nothing but what the
/// package already resolves, and adding a dependency so a daemon can have
/// `--help` is a poor trade.
///
/// Every path is derived from an injected environment rather than read from the
/// process's, so a test can point the whole daemon at a temporary directory
/// without mutating the environment of everything running beside it.
public struct DaemonOptions: Sendable {
    public static let usage = """
        skrepkad — the Skrepka clipboard daemon.

        USAGE
          skrepkad [options]

        OPTIONS
          --name NAME       what this device calls itself on the network
                            (default: this machine's hostname)
          --no-sync         watch the clipboard, but do not join the network
          --port N          sync listener port (default: any free port)
          --data-dir PATH   override $XDG_DATA_HOME/skrepka
          --config PATH     override $XDG_CONFIG_HOME/skrepka/config.json
          --log-level LEVEL trace | debug | info | notice | warning | error |
                            critical (default: info)
          --version         print the version and exit
          --help            print this and exit

        The daemon is normally started by systemd rather than by hand:
          systemctl --user enable --now skrepkad

        Its interface is the `skrepka` command, which talks to it over the
        session bus. `skrepka doctor` is the first thing to run when something
        is wrong.
        """

    public enum Command: Sendable {
        case run
        case help
        case version
    }

    public var command: Command = .run

    /// What this device advertises as. Empty means "ask the machine", which
    /// ``DeviceName/current()`` answers.
    public var displayName = ""

    /// Whether to join the network at all.
    ///
    /// Off is a real configuration rather than a debugging aid: a machine can
    /// usefully keep a local clipboard history and never pair with anything,
    /// and that user should not have a listener bound or a record published.
    public var syncEnabled = true

    public var port = 0
    public var logLevel = "info"

    /// Where the database and the device key live. Nil means the XDG default.
    public var dataDirectory: URL?
    /// Where the settings file lives. Nil means the XDG default.
    public var configURL: URL?

    public init() {}

    /// Parses `CommandLine.arguments`, minus the executable name.
    ///
    /// An unknown flag is an error rather than something ignored. A daemon that
    /// silently dropped `--no-sync` would advertise a machine its owner asked
    /// to keep off the network.
    public static func parse(_ arguments: [String]) throws -> DaemonOptions {
        var options = DaemonOptions()
        var rest = arguments[...]
        while let flag = rest.first {
            rest = rest.dropFirst()
            // `--help` and `--version` stop parsing rather than setting a field
            // and carrying on: someone asking for either has already said they
            // do not know the flags, so validating the rest would answer a
            // question about a typo instead of the one they asked.
            if let stopping = Self.stoppingCommand(for: flag) {
                options.command = stopping
                return options
            }
            try options.apply(flag, from: &rest)
        }
        return options
    }

    private static func stoppingCommand(for flag: String) -> Command? {
        switch flag {
        case "--help", "-h", "help": .help
        case "--version": .version
        default: nil
        }
    }

    /// One flag, and the value it takes if it takes one.
    private mutating func apply(_ flag: String, from rest: inout ArraySlice<String>) throws {
        switch flag {
        case "--no-sync":
            syncEnabled = false
        case "--name":
            displayName = try Self.value(&rest, for: flag)
        case "--log-level":
            logLevel = try Self.level(&rest, for: flag)
        case "--port":
            port = try Self.port(&rest, for: flag)
        case "--data-dir":
            dataDirectory = URL(
                filePath: try Self.value(&rest, for: flag), directoryHint: .isDirectory)
        case "--config":
            configURL = URL(
                filePath: try Self.value(&rest, for: flag), directoryHint: .notDirectory)
        default:
            throw DaemonOptionsError.unknownFlag(flag)
        }
    }

    /// The database file, honouring `--data-dir` and otherwise the XDG rules.
    public func storeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let dataDirectory else { return SessionPaths.historyStoreURL(environment: environment) }
        return dataDirectory.appending(path: "skrepka.sqlite3", directoryHint: .notDirectory)
    }

    /// The device key, same rules.
    public func deviceKeyURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard let dataDirectory else { return SessionPaths.deviceKeyURL(environment: environment) }
        return dataDirectory.appending(path: "device.key", directoryHint: .notDirectory)
    }

    public func settingsURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configURL ?? SessionPaths.configURL(environment: environment)
    }

    private static func value(_ rest: inout ArraySlice<String>, for flag: String) throws -> String {
        guard let value = rest.first else { throw DaemonOptionsError.missingValue(flag: flag) }
        rest = rest.dropFirst()
        return value
    }

    /// A TCP port, or `0` for "any free one".
    ///
    /// Validated here rather than absorbed into a default. `--port eighty` used
    /// to become an ephemeral port that disagreed with whatever firewall rule
    /// the user had just written, and `--port 99999` reached NIO's
    /// `SocketAddress(ipAddress:port:)`, which narrows to `in_port_t` — a
    /// `UInt16` — without checking, and killed the daemon on a fatal error
    /// where a usage message belonged.
    private static func port(_ rest: inout ArraySlice<String>, for flag: String) throws -> Int {
        let text = try value(&rest, for: flag)
        guard let number = Int(text), number >= 0, number <= 65535 else {
            throw DaemonOptionsError.invalidValue(text, flag: flag, expected: "0, or 1 to 65535")
        }
        return number
    }

    /// A swift-log level, spelled exactly as `Logger.Level` spells it.
    ///
    /// Refused rather than absorbed: `--log-level dbeug` used to start the
    /// daemon at `info`, so somebody debugging a sync failure got no trace and
    /// no hint that their flag had done nothing.
    private static func level(_ rest: inout ArraySlice<String>, for flag: String) throws -> String {
        let text = try value(&rest, for: flag)
        guard Logger.Level(rawValue: text) != nil else {
            throw DaemonOptionsError.invalidValue(
                text,
                flag: flag,
                expected: Logger.Level.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        return text
    }
}

public enum DaemonOptionsError: Error, Sendable, CustomStringConvertible {
    case unknownFlag(String)
    case missingValue(flag: String)
    /// The flag took a value this build cannot use. Carries what it wanted, so
    /// the message can say so rather than repeating the usage block.
    case invalidValue(String, flag: String, expected: String)

    public var description: String {
        switch self {
        case .unknownFlag(let flag): "unknown option \(flag)"
        case .missingValue(let flag): "\(flag) needs a value"
        case .invalidValue(let value, let flag, let expected):
            "\(flag) does not accept \"\(value)\" — it takes \(expected)"
        }
    }
}
