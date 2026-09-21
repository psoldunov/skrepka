import Testing

@testable import SkrepkaLinuxUI

/// Every spelling `skrepka-gui` accepts, and the ones it refuses.
@Suite("App: command line")
struct AppCommandTests {
    @Test(
        "each option asks for its command",
        arguments: [
            ([], AppCommand.showPicker),
            (["--picker"], .togglePicker),
            (["--settings"], .openSettings),
            (["--background"], .background),
            (["--quit"], .quit),
            (["--help"], .help),
            (["-h"], .help),
        ] as [([String], AppCommand)]
    )
    func parses(arguments: [String], expected: AppCommand) {
        #expect(AppCommand.parse(arguments) == .success(expected))
    }

    @Test("an option it does not know is refused by name")
    func refusesUnknown() {
        #expect(AppCommand.parse(["--pikcer"]) == .failure(.unknownOption("--pikcer")))
    }

    /// Two requests at once rarely mean anything together, and taking the
    /// first would silently ignore the second.
    @Test("two options at once are refused rather than half-followed")
    func refusesTwo() {
        #expect(
            AppCommand.parse(["--picker", "--settings"])
                == .failure(.tooManyOptions(["--picker", "--settings"])))
    }

    @Test("the usage names every option")
    func usageNamesEveryOption() {
        for option in ["--picker", "--settings", "--background", "--quit"] {
            #expect(AppCommand.usage.contains(option))
        }
    }
}
