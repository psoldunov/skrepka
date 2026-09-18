import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// The strings and flags the Settings window's widgets copy onto the screen.
@Suite("Settings: what the pane and the dialog say")
struct SyncPresentationTests {
    typealias Fixture = SyncFixtures

    // MARK: - The pane

    @Test("before the daemon has answered, the list says it is connecting and nothing can be done")
    func connecting() {
        let state = SyncPaneState(SyncModel(), now: Fixture.now, timeZone: .gmt)
        #expect(state.emptyMessage == "Connecting to Skrepka…")
        #expect(state.pairingSwitch.isEnabled == false)
        #expect(state.banner == nil)
    }

    @Test("the daemon's failure outranks a notice, and sync being off is said plainly")
    func bannerPriority() {
        let failure = SyncFailure(
            message: "The Skrepka daemon is not running.", remedy: "systemctl --user start skrepkad")
        let failed = Fixture.model(Fixture.document()).applying(.unreachable(failure), now: Fixture.now).model
        let banner = SyncPaneState(failed, now: Fixture.now, timeZone: .gmt).banner
        #expect(banner?.message == failure.message)
        #expect(banner?.detail == failure.remedy)
        #expect(banner?.isDismissible == false)

        let off = SyncPaneState(
            Fixture.model(Fixture.document(localFingerprint: "")), now: Fixture.now, timeZone: .gmt)
        #expect(off.banner?.message.hasPrefix("Sync is turned off") == true)
        #expect(off.pairingSwitch.isEnabled == false)
    }

    @Test("Sync Now appears only once something is paired")
    func syncNowNeedsAPairedDevice() {
        #expect(
            SyncPaneState(
                Fixture.model(Fixture.document([Fixture.nearby()])), now: Fixture.now, timeZone: .gmt
            ).showsSyncNow == false)
        #expect(
            SyncPaneState(
                Fixture.model(Fixture.document([Fixture.paired()])), now: Fixture.now, timeZone: .gmt
            ).showsSyncNow)
    }

    @Test("rows are disabled while a pairing is on screen")
    func promptDisablesRows() {
        let asked = Fixture.model(Fixture.document([Fixture.paired(), Fixture.nearby()]))
            .applying(.pairingRequested(Fixture.proposal(Fixture.laptopID)), now: Fixture.now).model
        let rows = SyncPaneState(asked, now: Fixture.now, timeZone: .gmt).rows
        #expect(rows.map(\.action) == [.unpair(isEnabled: false), .pair(isEnabled: false)])
    }

    // MARK: - A row

    @Test(
        "one line under the name: a failure, then connecting, then out of reach, then the last sync",
        arguments: [
            (
                SyncFixtures.paired(linkState: "failed: handshake timed out"),
                "Could not connect: handshake timed out"
            ),
            (SyncFixtures.paired(linkState: "connecting"), "Connecting…"),
            (SyncFixtures.paired(isSighted: false), "Not on this network right now"),
            (SyncFixtures.paired(), "Synced 1 minute ago"),
            (SyncFixtures.paired(lastSyncedAt: nil), "Paired — ABABABAB"),
            (SyncFixtures.nearby(), "On this network — CDCDCDCD"),
            (SyncFixtures.nearby(isAccepting: false), "Not accepting new pairings — CDCDCDCD"),
        ]
    )
    func subtitle(peer: PeerDocument, expected: String) {
        #expect(PeerRowState.subtitle(peer, now: Fixture.now) == expected)
    }

    @Test("a device that is not accepting pairings cannot be dialled")
    func notAcceptingDisablesPair() {
        let model = Fixture.model(Fixture.document([Fixture.nearby(isAccepting: false)]))
        let rows = SyncPaneState(model, now: Fixture.now, timeZone: .gmt).rows
        #expect(rows.first?.action == .pair(isEnabled: false))
    }

    @Test("a live-push flip holds its position, disabled, until the daemon answers")
    func livePushFlipIsHeld() {
        let flipped = Fixture.model(Fixture.document([Fixture.paired()])).sending(
            .setLivePush(deviceID: Fixture.macID, isOn: false))
        let live = SyncPaneState(flipped, now: Fixture.now, timeZone: .gmt).rows.first?.livePush
        #expect(live?.isOn == false)
        #expect(live?.isEnabled == false)
    }

    @Test("the sentence beside the switch says why it is where it is")
    func livePushExplanation() {
        let names = (PeerDocument.LivePushChoiceName.self, PeerDocument.LivePushDefaultName.self)
        #expect(
            PeerRowState.explanation(choice: names.0.off, reason: names.1.on, isOn: false)
                == "Only history is shared with this device.")
        #expect(
            PeerRowState.explanation(choice: names.0.followsPlatformDefault, reason: names.1.on, isOn: true)
                == "What you copy here goes straight to this device's clipboard.")
        let offUntilConnected = PeerRowState.explanation(
            choice: names.0.followsPlatformDefault,
            reason: names.1.offForUnrecognisedPlatform,
            isOn: false
        )
        #expect(offUntilConnected.hasPrefix("Off until this device connects"))
    }

    @Test("a daemon without SetLivePush shows the switch but will not let it move")
    func olderDaemonCannotSet() {
        let old = Fixture.model(Fixture.document([Fixture.paired(choice: nil, reason: nil)]))
        let live = SyncPaneState(old, now: Fixture.now, timeZone: .gmt).rows.first?.livePush
        #expect(live?.isEnabled == false)
        #expect(live?.explanation.contains("update skrepkad") == true)
    }

    // MARK: - The dialog

    @Test("dialling shows no code and cannot be confirmed")
    func diallingText() {
        let prompt = PairingPrompt.dialling(Fixture.nearby())
        let text = PairingPromptText(prompt, now: Fixture.now)
        #expect(text.title == "Pair with Deck")
        #expect(text.code == nil)
        #expect(text.isWorking)
        #expect(text.isConfirmEnabled == false)
    }

    @Test("a code says who asked, what to check, and how long is left")
    func comparingText() {
        let prompt = PairingPrompt.comparing(Fixture.proposal(expiresIn: 65))
        let text = PairingPromptText(prompt, now: Fixture.now)
        #expect(text.title == "Deck wants to pair")
        #expect(text.code == "A3F2-91BC-D4E7-0182")
        #expect(text.status.contains("Check that Deck is showing exactly this code."))
        #expect(text.status.hasSuffix("This code is good for 1:05 more."))
        #expect(text.isConfirmEnabled)
        #expect(text.confirmLabel == "Codes Match — Pair")
    }

    @Test("an ended pairing can only be closed")
    func endedText() {
        let prompt = PairingPrompt.comparing(Fixture.proposal()).moved(to: .ended(PairingPrompt.tookTooLong))
        let text = PairingPromptText(prompt, now: Fixture.now)
        #expect(text.cancelLabel == "Close")
        #expect(text.confirmLabel == nil)
        #expect(text.status == PairingPrompt.tookTooLong)
    }
}
