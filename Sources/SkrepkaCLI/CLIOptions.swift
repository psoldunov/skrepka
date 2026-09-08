import Foundation
import SkrepkaIPC

/// How `skrepka` was invoked.
///
/// Hand-parsed rather than through `ArgumentParser`, for the reason
/// `ProbeOptions` is: the CLI has to build on Linux out of what `SkrepkaIPC`
/// already pulls in, and a package dependency resolved on every build of the
/// macOS app so that a Linux binary can have `--help` is a poor trade.
///
/// A flag is accepted only by the commands it means something to — `--limit`
/// belongs to `list` and nowhere else — because a flag quietly ignored is a
/// command that looks obeyed and was not.
public struct CLIOptions: Sendable, Hashable {
    public enum Command: Sendable, Hashable {
        /// `limit` of 0 is every entry, matching the bus member.
        case list(limit: UInt32)
        case copy(ClipSelector)
        case pair(peer: String?, seconds: UInt32)
        case peers
        case doctor
        case sync
        case unpair(fingerprint: String)
        case help
    }

    public let command: Command

    /// Whether to print the daemon's document verbatim rather than a rendering
    /// of it. Only ever true for a command that offers it.
    public let isJSON: Bool

    public init(command: Command, isJSON: Bool = false) {
        self.command = command
        self.isJSON = isJSON
    }

    /// How long `skrepka pair` leaves this device accepting dials when no peer
    /// was named. Long enough to walk to the other machine, short enough that a
    /// window nobody closed is not open all afternoon.
    public static let defaultPairingSeconds: UInt32 = 120

    public static let usage = """
        skrepka — the clipboard history and its peers, from the command line.

        USAGE
          skrepka list   [--limit N] [--json]   history, newest first, pinned first
          skrepka copy   <n|hash>               put one entry back on the clipboard
          skrepka pair   [--peer FINGERPRINT] [--timeout SECONDS]
                                                pair with another device
          skrepka peers  [--json]               paired and sighted devices
          skrepka doctor [--json]               what is working on this machine
          skrepka sync                          exchange indexes with every peer now
          skrepka unpair <fingerprint>          forget a paired device
          skrepka help                          this text

        NOTES
          `copy 3` names the third line of the last `list`; `copy a1b2c3` names an
          entry by content hash, or by any prefix long enough to be unambiguous.

          `pair` without --peer opens this device to pairing for --timeout seconds
          (default \(defaultPairingSeconds)) and waits for another device to dial in. Either way both
          screens must show the same words before you answer yes.

          --json prints the daemon's own document, unchanged, for scripts.

        EXIT
          0 done   1 the daemon reported a failure   2 the command line was wrong
        """

    /// Parses `CommandLine.arguments`, minus the executable name.
    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        guard let name = arguments.first else { throw CLIError.missingCommand }
        if ["help", "--help", "-h"].contains(name) {
            return CLIOptions(command: .help)
        }
        let verb = try Verb(name)
        let flags = try Flags(parsing: Array(arguments.dropFirst()), for: verb)
        return CLIOptions(command: try flags.command(for: verb), isJSON: flags.isJSON)
    }
}

// MARK: - The verb

extension CLIOptions {
    /// The first word, before any flag has been looked at.
    ///
    /// Separate from ``CLIOptions/Command`` because the flags are parsed
    /// against it: which options are legal depends on the verb, and the verb is
    /// known before its arguments are.
    enum Verb: String, Sendable, Hashable {
        case list, copy, pair, peers, doctor, sync, unpair

        init(_ name: String) throws {
            guard let verb = Verb(rawValue: name) else { throw CLIError.unknownCommand(name) }
            self = verb
        }

        var acceptsJSON: Bool {
            switch self {
            case .list, .peers, .doctor: true
            case .copy, .pair, .sync, .unpair: false
            }
        }
    }
}

// MARK: - The flags

extension CLIOptions {
    /// Everything after the verb, in the shape the verb will read it.
    private struct Flags {
        var isJSON = false
        var limit: UInt32 = 0
        var peer: String?
        var seconds = CLIOptions.defaultPairingSeconds
        var positionals: [String] = []

        init(parsing arguments: [String], for verb: Verb) throws {
            var rest = arguments[...]
            while let token = rest.first {
                rest = rest.dropFirst()
                if token.hasPrefix("-") {
                    try apply(token, for: verb, from: &rest)
                } else {
                    positionals.append(token)
                }
            }
        }

        private mutating func apply(
            _ flag: String,
            for verb: Verb,
            from rest: inout ArraySlice<String>
        ) throws {
            switch flag {
            case "--json" where verb.acceptsJSON: isJSON = true
            case "--limit" where verb == .list: limit = try Self.number(&rest, for: flag)
            case "--peer" where verb == .pair: peer = try Self.value(&rest, for: flag)
            case "--timeout" where verb == .pair: seconds = try Self.number(&rest, for: flag)
            default: throw CLIError.unknownFlag(flag, command: verb.rawValue)
            }
        }

        private static func value(
            _ rest: inout ArraySlice<String>,
            for flag: String
        ) throws -> String {
            guard let value = rest.first, !value.hasPrefix("-") else {
                throw CLIError.missingValue(flag: flag)
            }
            rest = rest.dropFirst()
            return value
        }

        private static func number(
            _ rest: inout ArraySlice<String>,
            for flag: String
        ) throws -> UInt32 {
            let text = try value(&rest, for: flag)
            guard let number = UInt32(text) else {
                throw CLIError.invalidValue(text, flag: flag)
            }
            return number
        }

        func command(for verb: Verb) throws -> Command {
            switch verb {
            case .list:
                try none(verb)
                return .list(limit: limit)
            case .peers:
                try none(verb)
                return .peers
            case .doctor:
                try none(verb)
                return .doctor
            case .sync:
                try none(verb)
                return .sync
            case .copy: return .copy(try selector(verb))
            case .unpair: return .unpair(fingerprint: try one(verb, named: "a fingerprint"))
            case .pair:
                try none(verb)
                return .pair(peer: peer, seconds: seconds)
            }
        }

        /// `copy 0` and `copy ""` are usage errors rather than hash prefixes:
        /// the list this names is one-based, and a zero read as a prefix
        /// matches every hash that starts with one.
        private func selector(_ verb: Verb) throws -> ClipSelector {
            let text = try one(verb, named: "an entry, as `3` or a hash")
            guard let selector = ClipSelector(validating: text) else {
                throw CLIError.invalidArgument(
                    text,
                    command: verb.rawValue,
                    reason: "entries are numbered from 1, and a hash needs at least one character"
                )
            }
            return selector
        }

        private func none(_ verb: Verb) throws {
            if let extra = positionals.first {
                throw CLIError.unexpectedArgument(extra, command: verb.rawValue)
            }
        }

        private func one(_ verb: Verb, named expected: String) throws -> String {
            guard let value = positionals.first else {
                throw CLIError.missingArgument(command: verb.rawValue, expected: expected)
            }
            if positionals.count > 1 {
                throw CLIError.unexpectedArgument(positionals[1], command: verb.rawValue)
            }
            return value
        }
    }
}
