import Testing

@testable import SkrepkaCore

@Suite("Paste-back status")
struct PasteBackStatusTests {
    private func status(
        trusted: Bool = false,
        pasteAutomatically: Bool = true,
        didRequest: Bool = false
    ) -> PasteBackStatus {
        PasteBackStatus(
            isAccessibilityTrusted: trusted,
            pasteAutomatically: pasteAutomatically,
            didRequest: didRequest
        )
    }

    @Test("Granted Accessibility is working")
    func trustedIsWorking() {
        #expect(status(trusted: true) == .working)
        #expect(status(trusted: true, didRequest: true) == .working)
    }

    @Test("A fresh install has not been asked yet")
    func freshInstallHasNotAsked() {
        #expect(status() == .notAsked)
    }

    @Test("Asking without being granted sends the user to System Settings")
    func askingWithoutTrustAwaitsSettings() {
        // The prompt answers asynchronously and does not change the return
        // value, so a second ask would tell us nothing the first did not.
        #expect(status(didRequest: true) == .awaitingSettings)
    }

    @Test("Turning off automatic pasting withdraws the request")
    func pasteBackOffNeedsNothing() {
        #expect(status(pasteAutomatically: false) == .notNeeded)
        #expect(status(pasteAutomatically: false, didRequest: true) == .notNeeded)
        // Even a granted permission is not something to keep asking about.
        #expect(status(trusted: true, pasteAutomatically: false) == .notNeeded)
    }

    @Test("Only working and not-needed are settled")
    func settledStates() {
        let settled = PasteBackStatus.allCases.filter(\.isSettled)
        #expect(Set(settled) == [.working, .notNeeded])
    }

    @Test("Omitting didRequest reads as not having asked")
    func didRequestDefaultsToFalse() {
        // The badge and the diagnostics snapshot cannot know whether a prompt
        // was shown. The default must not invent an answer that changes
        // `isSettled`, which is all either of them looks at.
        let assumed = PasteBackStatus(isAccessibilityTrusted: false, pasteAutomatically: true)
        #expect(assumed == .notAsked)
        #expect(assumed.isSettled == status(didRequest: true).isSettled)
    }
}
