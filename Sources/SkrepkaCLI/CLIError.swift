import Foundation

/// A command line this build cannot act on.
///
/// Every case is a usage error and therefore exit code 2 — the user typed
/// something wrong, as opposed to the daemon reporting a failure, which is 1.
/// Separating them is what lets a script tell "I called this wrongly" from "the
/// thing I asked for did not happen".
public enum CLIError: Error, Sendable, Hashable, CustomStringConvertible {
    /// `skrepka` on its own.
    case missingCommand

    case unknownCommand(String)

    /// An unknown flag is an error rather than something ignored: a CLI that
    /// silently dropped `--limit 5` would print the whole history and look like
    /// it had obeyed.
    case unknownFlag(String, command: String)

    /// A flag that takes a value, given none.
    case missingValue(flag: String)

    case invalidValue(String, flag: String)

    /// A command missing its positional argument.
    case missingArgument(command: String, expected: String)

    /// A positional argument that is present and names nothing — `copy 0`,
    /// where the entry numbering starts at 1. Refused here rather than passed
    /// on, because the daemon would have to guess what was meant and the
    /// cheapest guess pastes the wrong thing.
    case invalidArgument(String, command: String, reason: String)

    case unexpectedArgument(String, command: String)

    public var description: String {
        switch self {
        case .missingCommand:
            "no command given"
        case .unknownCommand(let name):
            "there is no `skrepka \(name)` command"
        case .unknownFlag(let flag, let command):
            "`skrepka \(command)` takes no \(flag) option"
        case .missingValue(let flag):
            "\(flag) needs a value after it"
        case .invalidValue(let value, let flag):
            "\(flag) does not take `\(value)`"
        case .missingArgument(let command, let expected):
            "`skrepka \(command)` needs \(expected)"
        case .invalidArgument(let value, let command, let reason):
            "`skrepka \(command)` cannot use `\(value)`: \(reason)"
        case .unexpectedArgument(let value, let command):
            "`skrepka \(command)` takes no argument, and was given `\(value)`"
        }
    }
}
