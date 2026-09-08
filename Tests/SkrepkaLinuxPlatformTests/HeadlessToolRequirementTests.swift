import Foundation
import Testing

/// The check that stops a skip from passing for a pass.
///
/// Every live backend test is gated with
/// `.enabled(if: HeadlessSession.isAvailable(...))`, which is right for a
/// developer's own Linux checkout: a machine without sway or Xvfb should still
/// run the unit half rather than fail. It is wrong for the containerised gate,
/// where the tools are installed on purpose — a `docker/Dockerfile.linux`
/// regression that dropped one of them would silently disable seventeen tests
/// and the gate would still report green.
///
/// So this suite is **not** gated. It passes trivially unless
/// `SKREPKA_REQUIRE_HEADLESS` is set to a truthy value, and
/// `scripts/doctor-linux.sh` sets it for its own `swift test` run and nowhere
/// else. The environment decides whether a missing compositor is a skip or a
/// failure, which is exactly the thing the test file cannot know.
@Suite("Headless tool requirement")
struct HeadlessToolRequirementTests {
    /// The variable that turns an absent compositor into a failure.
    static let requirementVariable = "SKREPKA_REQUIRE_HEADLESS"

    /// Unset, empty, `0`, `false` and `no` all mean "not required". Anything
    /// else is truthy, so `=1` reads the way a shell author expects.
    static func isEnforced(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let raw = environment[requirementVariable] else { return false }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !["", "0", "false", "no"].contains(value)
    }

    @Test("SKREPKA_REQUIRE_HEADLESS is off unless it is set to something truthy")
    func parsesTheRequirementVariable() {
        let variable = Self.requirementVariable
        #expect(!Self.isEnforced(environment: [:]))
        #expect(!Self.isEnforced(environment: [variable: "0"]))
        #expect(!Self.isEnforced(environment: [variable: " False "]))
        #expect(Self.isEnforced(environment: [variable: "1"]))
        #expect(Self.isEnforced(environment: [variable: "yes"]))
    }

    @Test("the headless tools are installed where the environment requires them")
    func toolsArePresentWhenRequired() {
        guard Self.isEnforced() else { return }

        let missing =
            HeadlessSession.missingTools(.sway) + HeadlessSession.missingTools(.xvfb)
        #expect(
            missing.isEmpty,
            """
            \(missing.joined(separator: ", ")) not on PATH, so the live Wayland \
            and X11 suites would have skipped silently. \
            \(Self.requirementVariable) is set, which makes that a failure — \
            scripts/doctor-linux.sh sets it because docker/Dockerfile.linux is \
            supposed to install every one of \
            \(HeadlessSession.requiredTools(.sway).joined(separator: ", ")), \
            \(HeadlessSession.requiredTools(.xvfb).joined(separator: ", ")). \
            Unset it to run the unit tests alone.
            """
        )
    }
}
