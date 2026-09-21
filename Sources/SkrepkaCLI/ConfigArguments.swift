import Foundation
import SkrepkaIPC

/// `skrepka config` and `skrepka config set <key> <value>`, from positionals
/// to a command.
///
/// Its own type rather than more of ``CLIOptions``: the keys and the values
/// they take are a small language of their own, and every rule here is one a
/// test names.
enum ConfigArguments {
    /// The keys `config set` takes, spelled as the user types them.
    enum Key: String, CaseIterable, Sendable {
        case retentionItems = "retention.items"
        case retentionDays = "retention.days"
        case syncEnabled = "sync.enabled"
    }

    static let verb = "config"
    private static let setWord = "set"
    private static let unlimitedWord = "unlimited"

    /// `positionals` is everything after `config` that was not a flag.
    static func command(positionals: [String], isJSON: Bool) throws -> CLIOptions.Command {
        guard let first = positionals.first else { return .config }
        guard first == setWord else {
            throw CLIError.unexpectedArgument(first, command: verb)
        }
        if isJSON { throw CLIError.unknownFlag("--json", command: "\(verb) \(setWord)") }
        let rest = positionals.dropFirst()
        guard let keyText = rest.first else {
            throw CLIError.missingArgument(command: "\(verb) \(setWord)", expected: "a key and a value")
        }
        guard let key = Key(rawValue: keyText) else {
            throw CLIError.invalidArgument(
                keyText,
                command: "\(verb) \(setWord)",
                reason: "the keys are \(Key.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard rest.count >= 2 else {
            throw CLIError.missingArgument(command: "\(verb) \(setWord) \(keyText)", expected: "a value")
        }
        let values = rest.dropFirst()
        if values.count > 1 {
            throw CLIError.unexpectedArgument(values[values.startIndex + 1], command: "\(verb) \(setWord)")
        }
        return .configure(try patch(key, values[values.startIndex]))
    }

    /// One key and its value, as the patch that changes it.
    static func patch(_ key: Key, _ value: String) throws -> SettingsPatch {
        let patch: SettingsPatch
        switch key {
        case .retentionItems: patch = SettingsPatch(maximumItems: try limit(value, key: key))
        case .retentionDays: patch = SettingsPatch(maximumAgeDays: try limit(value, key: key))
        case .syncEnabled: patch = SettingsPatch(syncEnabled: try switchValue(value, key: key))
        }
        // The daemon checks again and is the authority; asking here first makes
        // a typo exit 2 with the reason, rather than a round trip and exit 1.
        if let refusal = patch.refusal {
            throw CLIError.invalidArgument(
                value, command: "\(verb) \(setWord) \(key.rawValue)", reason: refusal)
        }
        return patch
    }

    /// A whole number, or `unlimited` for 0.
    private static func limit(_ value: String, key: Key) throws -> Int {
        if value == unlimitedWord { return 0 }
        guard let number = Int(value) else {
            throw CLIError.invalidArgument(
                value,
                command: "\(verb) \(setWord) \(key.rawValue)",
                reason: "it takes a whole number, or `\(unlimitedWord)`")
        }
        return number
    }

    private static func switchValue(_ value: String, key: Key) throws -> Bool {
        switch value {
        case "on": return true
        case "off": return false
        default:
            throw CLIError.invalidArgument(
                value, command: "\(verb) \(setWord) \(key.rawValue)", reason: "it takes `on` or `off`")
        }
    }
}
