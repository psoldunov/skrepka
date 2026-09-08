import SkrepkaIPC
import Testing

@testable import SkrepkaCLI

/// The exit codes, which ``CLIRunner`` calls a contract and the Phase 8
/// packaging tests script against: `0` it happened, `1` the daemon reported it
/// did not, `2` the command line was wrong.
///
/// Only the paths that need no bus are here. Everything that reaches
/// ``SkrepkaBus/withDaemon(logger:_:)`` needs a session bus and a running
/// daemon, and a test that passes on a developer's desktop and fails in a build
/// container is worse than no test — the exit codes for those paths are pinned
/// through ``CLIOutcome`` instead, which is where the decision actually lives.
@Suite("CLI exit codes")
struct CLIRunnerTests {
    @Test("a command line that is wrong exits 2, before any bus is touched")
    func usageErrorsExitTwo() async {
        #expect(await CLIRunner.run(["lsit"]) == 2)
        #expect(await CLIRunner.run([]) == 2)
        #expect(await CLIRunner.run(["list", "--peer", "ab"]) == 2)
        #expect(await CLIRunner.run(["copy", "0"]) == 2)
        #expect(await CLIRunner.run(["copy"]) == 2)
    }

    @Test("help exits 0")
    func helpExitsZero() async {
        for spelling in ["help", "--help", "-h"] {
            #expect(await CLIRunner.run([spelling]) == 0)
        }
    }

    @Test("an outcome the daemon refused is exit 1")
    func refusedOutcomeExitsOne() {
        #expect(CLIOutcome.report(.refused("nothing to copy"), whenSilent: "Copied.") == 1)
        #expect(CLIOutcome.report(.refused(""), whenSilent: "Copied.") == 1)
    }

    @Test("an outcome that succeeded is exit 0, silent or not")
    func succeededOutcomeExitsZero() {
        #expect(CLIOutcome.report(.succeeded("Copied entry 3."), whenSilent: "Copied.") == 0)
        // The dull success: the daemon had nothing to say, so `whenSilent`
        // carries the line rather than the command printing nothing.
        #expect(CLIOutcome.report(.succeeded(), whenSilent: "Copied.") == 0)
    }
}
