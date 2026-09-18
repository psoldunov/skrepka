import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// What the Settings window decides when the daemon answers — everything but
/// pairing, which has its own suite.
@Suite("Settings: the sync model")
struct SyncModelTests {
    typealias Fixture = SyncFixtures

    @Test("a flipped switch is in flight until the daemon answers, and keeps the user's position")
    func pairingSwitchFollowsTheFlip() {
        let closed = Fixture.model(Fixture.document([Fixture.paired()]))
        let opening = closed.sending(.openPairingWindow)
        let during = SyncPaneState(opening, now: Fixture.now, timeZone: .gmt).pairingSwitch
        #expect(during.isOn)
        #expect(during.isEnabled == false)

        let window = PairingWindowDocument(port: 5555, expiresAt: Fixture.now + 300)
        let refreshed = Fixture.document([Fixture.paired()], pairingPort: 5555)
        let finished = SyncEvent.finished(.openPairingWindow, .opened(window), refreshed: refreshed)
        let opened = opening.applying(finished, now: Fixture.now).model
        let after = SyncPaneState(opened, now: Fixture.now, timeZone: .gmt).pairingSwitch
        #expect(opened.inFlight.isEmpty)
        #expect(after.isOn)
        #expect(after.isEnabled)
        #expect(after.subtitle.hasPrefix("Open until 08:05"))
    }

    @Test("a poll that says the window is closed clears the expiry it had")
    func expiredWindowIsForgotten() {
        let window = PairingWindowDocument(port: 5555, expiresAt: Fixture.now + 300)
        let open = Fixture.model(Fixture.document())
            .sending(.openPairingWindow)
            .applying(.finished(.openPairingWindow, .opened(window), refreshed: nil), now: Fixture.now).model
        #expect(open.pairingWindowEndsAt != nil)

        let polled = open.applying(.refreshed(Fixture.document()), now: Fixture.now).model
        #expect(polled.pairingWindowEndsAt == nil)
    }

    @Test("an unreachable daemon keeps the list and says why; the next answer clears it")
    func unreachableThenBack() {
        let failure = SyncFailure(message: "The Skrepka daemon is not running.", remedy: "start it")
        let model = Fixture.model(Fixture.document([Fixture.paired()])).applying(
            .unreachable(failure), now: Fixture.now
        ).model
        #expect(model.failure == failure)
        #expect(model.peers?.peers.count == 1)
        #expect(model.isSyncAvailable == false)

        let back = model.applying(.refreshed(Fixture.document([Fixture.paired()])), now: Fixture.now).model
        #expect(back.failure == nil)
        #expect(back.isSyncAvailable)
    }

    @Test("good news clears itself; a problem stays until dismissed")
    func noticeLifetimes() {
        let unpaired = Fixture.model(Fixture.document([Fixture.paired()]))
            .sending(.unpair(deviceID: Fixture.macID))
            .applying(
                .finished(
                    .unpair(deviceID: Fixture.macID),
                    .answered(.succeeded("forgot MacBook", subject: "ABABABAB")),
                    refreshed: Fixture.document()
                ),
                now: Fixture.now
            ).model
        #expect(unpaired.notice?.message == "Forgot MacBook.")
        #expect(unpaired.notice?.tone == .success)
        #expect(unpaired.expiring(now: Fixture.now + 60).notice == nil)

        let failure = SyncFailure(message: "The Skrepka daemon did not answer in time.")
        let failed = Fixture.model(Fixture.document())
            .sending(.syncNow)
            .applying(.finished(.syncNow, .failed(failure), refreshed: nil), now: Fixture.now).model
        #expect(failed.notice?.tone == .problem)
        #expect(failed.expiring(now: Fixture.now + 3600).notice != nil)
        #expect(failed.dismissingNotice().notice == nil)
    }

    @Test("Sync Now with nothing paired is an answer, not a fault")
    func syncNowWithNothingPaired() {
        let model = Fixture.model(Fixture.document())
            .sending(.syncNow)
            .applying(
                .finished(
                    .syncNow, .answered(.refused("no peers are paired with this device")), refreshed: nil),
                now: Fixture.now
            ).model
        #expect(model.notice?.tone == .info)
        #expect(model.notice?.message == "No peers are paired with this device.")
    }

    @Test("a live-push change says nothing in the banner; the switch already shows it")
    func livePushIsQuiet() {
        let model = Fixture.model(Fixture.document([Fixture.paired()]))
            .sending(.setLivePush(deviceID: Fixture.macID, isOn: false))
            .applying(
                .finished(
                    .setLivePush(deviceID: Fixture.macID, isOn: false),
                    .answered(.succeeded("live clipboard is off for MacBook")),
                    refreshed: Fixture.document([Fixture.paired(livePush: false, choice: "off")])
                ),
                now: Fixture.now
            ).model
        #expect(model.notice == nil)
        #expect(model.inFlight.isEmpty)
    }

    @Test("an action finishes the one in-flight copy it matches, and no other")
    func inFlightIsCounted() {
        let twice = Fixture.model(Fixture.document()).sending(.syncNow).sending(.syncNow)
        let once = twice.applying(
            .finished(.syncNow, .answered(.succeeded("asked 1 peer to sync")), refreshed: nil),
            now: Fixture.now
        ).model
        #expect(once.inFlight == [.syncNow])
    }
}
