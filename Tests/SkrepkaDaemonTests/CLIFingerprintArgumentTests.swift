import SkrepkaIPC
import Testing

@testable import SkrepkaCLI

/// A fingerprint that names every device rather than one.
///
/// Both selectors here are matched by prefix on the daemon side, and every
/// string has `""` as a prefix — so an empty selector is not "no peer", it is
/// "the first peer listed". `skrepka unpair ""` forgetting the only paired
/// device, and `skrepka pair --peer ""` dialling whichever peer was sighted
/// last, are the two ways that shows up.
///
/// The daemon refuses these as well and is the authority on them; what this
/// suite pins is the second layer, which exists so the user gets a message
/// naming the argument and exit code 2 rather than a daemon-side failure.
@Suite("CLI fingerprint arguments")
struct CLIFingerprintArgumentTests {
    /// Every spelling of "blank" a shell can hand over. Tabs and newlines
    /// included because `unpair "$(pbpaste)"` on an empty clipboard produces
    /// one of them rather than the empty string.
    static let blanks = ["", " ", "   ", "\t", "\n", " \t\n "]

    @Test("`unpair` refuses a blank fingerprint", arguments: CLIFingerprintArgumentTests.blanks)
    func unpairRefusesBlank(_ blank: String) {
        #expect(
            throws: CLIError.invalidArgument(
                blank,
                command: "unpair",
                reason: "a fingerprint has to name one device, and an empty one names any"
            )
        ) {
            try CLIOptions.parse(["unpair", blank])
        }
    }

    @Test("`pair --peer` refuses a blank fingerprint", arguments: CLIFingerprintArgumentTests.blanks)
    func pairRefusesBlankPeer(_ blank: String) {
        #expect(throws: CLIError.invalidValue(blank, flag: "--peer")) {
            try CLIOptions.parse(["pair", "--peer", blank])
        }
    }

    @Test("a blank fingerprint exits 2, before any bus is touched")
    func blankExitsTwo() async {
        // The exit code is the half a script reads, and this reaches it
        // honestly: a parse failure returns before ``CLIRunner`` opens a
        // connection, so no session bus is involved on any machine.
        #expect(await CLIRunner.run(["unpair", ""]) == 2)
        #expect(await CLIRunner.run(["unpair", "  "]) == 2)
        #expect(await CLIRunner.run(["pair", "--peer", ""]) == 2)
        #expect(await CLIRunner.run(["pair", "--peer", "  "]) == 2)
    }

    @Test("a fingerprint with content still parses, whitespace and all")
    func nonBlankIsUntouched() throws {
        // Checked rather than trimmed, so a selector with stray spaces reaches
        // the daemon exactly as typed: silently rewriting it would match a
        // different peer from the one on screen.
        #expect(try CLIOptions.parse(["unpair", " ab-cd "]).command == .unpair(fingerprint: " ab-cd "))
        #expect(
            try CLIOptions.parse(["pair", "--peer", "ab-cd"]).command
                == .pair(peer: "ab-cd", seconds: CLIOptions.defaultPairingSeconds))
    }

    @Test("`pair` with no --peer at all is still the open-a-window case")
    func absentPeerIsNotBlank() throws {
        // The refusal must not turn "no peer named" into an error: that is the
        // ordinary `skrepka pair` invocation, and it opens a pairing window.
        #expect(
            try CLIOptions.parse(["pair"]).command
                == .pair(peer: nil, seconds: CLIOptions.defaultPairingSeconds))
    }
}
