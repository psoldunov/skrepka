import SkrepkaIPC
import Testing

@testable import SkrepkaCLI

/// What `skrepka` does with a command line.
///
/// The unknown-flag cases are the ones that earn their keep: a flag silently
/// ignored is a command that looks obeyed and did something else.
@Suite("CLI arguments")
struct CLIOptionsTests {
    @Test("bare `list` asks for every entry")
    func listWithoutLimit() throws {
        let options = try CLIOptions.parse(["list"])
        #expect(options.command == .list(limit: 0))
        #expect(options.isJSON == false)
    }

    @Test("`list --limit 5 --json`")
    func listWithLimitAndJSON() throws {
        let options = try CLIOptions.parse(["list", "--limit", "5", "--json"])
        #expect(options.command == .list(limit: 5))
        #expect(options.isJSON)
    }

    @Test("a limit that is not a number is a usage error")
    func limitMustBeANumber() {
        #expect(throws: CLIError.invalidValue("soon", flag: "--limit")) {
            try CLIOptions.parse(["list", "--limit", "soon"])
        }
    }

    @Test("a flag that takes a value, given none")
    func limitNeedsAValue() {
        #expect(throws: CLIError.missingValue(flag: "--limit")) {
            try CLIOptions.parse(["list", "--limit"])
        }
        #expect(throws: CLIError.missingValue(flag: "--peer")) {
            try CLIOptions.parse(["pair", "--peer", "--timeout"])
        }
    }

    @Test("`copy` takes a position or a hash")
    func copySelectors() throws {
        #expect(try CLIOptions.parse(["copy", "3"]).command == .copy(.position(3)))
        #expect(try CLIOptions.parse(["copy", "A1B2"]).command == .copy(.hash("a1b2")))
    }

    @Test("`copy` needs something to copy, and only one thing")
    func copyArity() {
        #expect(throws: CLIError.self) { try CLIOptions.parse(["copy"]) }
        #expect(throws: CLIError.unexpectedArgument("4", command: "copy")) {
            try CLIOptions.parse(["copy", "3", "4"])
        }
    }

    @Test("`pair` defaults to opening a window on this device")
    func pairDefaults() throws {
        let options = try CLIOptions.parse(["pair"])
        #expect(options.command == .pair(peer: nil, seconds: CLIOptions.defaultPairingSeconds))
    }

    @Test("`pair --peer … --timeout …`")
    func pairWithPeer() throws {
        let options = try CLIOptions.parse(["pair", "--peer", "ab-cd", "--timeout", "30"])
        #expect(options.command == .pair(peer: "ab-cd", seconds: 30))
    }

    @Test("`unpair` needs a fingerprint")
    func unpair() throws {
        #expect(try CLIOptions.parse(["unpair", "ab-cd"]).command == .unpair(fingerprint: "ab-cd"))
        #expect(throws: CLIError.missingArgument(command: "unpair", expected: "a fingerprint")) {
            try CLIOptions.parse(["unpair"])
        }
    }

    @Test("`peers`, `doctor` and `sync` take no argument")
    func plainCommands() throws {
        #expect(try CLIOptions.parse(["peers", "--json"]).command == .peers)
        #expect(try CLIOptions.parse(["doctor", "--json"]).isJSON)
        #expect(try CLIOptions.parse(["sync"]).command == .sync)
        #expect(throws: CLIError.unexpectedArgument("now", command: "sync")) {
            try CLIOptions.parse(["sync", "now"])
        }
    }

    @Test("--json belongs only to the commands that print a document")
    func jsonIsNotUniversal() {
        for verb in ["copy", "sync", "pair", "unpair"] {
            #expect(throws: CLIError.unknownFlag("--json", command: verb)) {
                try CLIOptions.parse([verb, "--json", "x"])
            }
        }
    }

    @Test("a flag meant for another command is rejected, not ignored")
    func flagsAreScopedToTheirCommand() {
        #expect(throws: CLIError.unknownFlag("--limit", command: "peers")) {
            try CLIOptions.parse(["peers", "--limit", "5"])
        }
        #expect(throws: CLIError.unknownFlag("--peer", command: "list")) {
            try CLIOptions.parse(["list", "--peer", "ab-cd"])
        }
        #expect(throws: CLIError.unknownFlag("--verbose", command: "doctor")) {
            try CLIOptions.parse(["doctor", "--verbose"])
        }
    }

    @Test("help, and the empty command line")
    func help() throws {
        for spelling in ["help", "--help", "-h"] {
            #expect(try CLIOptions.parse([spelling]).command == .help)
        }
        #expect(throws: CLIError.missingCommand) { try CLIOptions.parse([]) }
        #expect(throws: CLIError.unknownCommand("lsit")) { try CLIOptions.parse(["lsit"]) }
    }

    @Test("a hash is lowercased and a position is one-based")
    func clipSelectors() {
        #expect(ClipSelector("1") == .position(1))
        #expect(ClipSelector("DEADBEEF") == .hash("deadbeef"))
        #expect(ClipSelector("3").wireValue == "3")
        // Deliberately changed: `0` and `-2` used to fall through to
        // `.hash("0")` and `.hash("-2")`, and `copy 0` then prefix-matched
        // every hash beginning with a zero. They now name nothing.
        #expect(ClipSelector("0") == .position(0))
        #expect(ClipSelector("-2") == .position(0))
    }

    @Test("`copy 0` is a usage error rather than a hash prefix")
    func copyRefusesNonPositions() throws {
        #expect(try CLIOptions.parse(["copy", "1"]).command == .copy(.position(1)))
        #expect(try CLIOptions.parse(["copy", "0a1b"]).command == .copy(.hash("0a1b")))
        for argument in ["0", "-1", ""] {
            #expect(throws: CLIError.self) { try CLIOptions.parse(["copy", argument]) }
        }
    }
}
