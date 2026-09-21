import SkrepkaLinuxPlatform
import Testing

@testable import SkrepkaLinuxUI

@Suite("Paste failure notices")
struct PasteCoordinatorTests {
    @Test("re-enabling automatic paste permits one new failure notice")
    func reenableResetsFailureNotice() {
        var alerts = 0
        let coordinator = PasteCoordinator(
            mechanism: .copyOnly,
            portalConnection: { nil },
            showAlert: { _, _ in alerts += 1 })

        coordinator.finished(.failure(PasteFailure("first")))
        coordinator.finished(.failure(PasteFailure("duplicate")))
        coordinator.setAutomaticPasteEnabled(true)
        coordinator.finished(.failure(PasteFailure("still duplicate")))
        coordinator.setAutomaticPasteEnabled(false)
        coordinator.setAutomaticPasteEnabled(true)
        coordinator.finished(.failure(PasteFailure("new refusal")))

        #expect(alerts == 2)
    }
}
