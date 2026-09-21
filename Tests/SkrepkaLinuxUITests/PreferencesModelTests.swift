import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

@Suite("Settings: the preferences model")
struct PreferencesModelTests {
    typealias Fixture = PreferencesFixtures
    let now = SyncFixtures.now

    @Test("a daemon older than version 4 is unsupported, not unreachable, and nothing is editable")
    func unsupported() {
        let model = PreferencesModel().applying(.loaded(.unsupported(3)), now: now)
        #expect(model.availability == .unsupported(3))
        #expect(!model.isEditable)
        let banner = PreferencesBanner.banner(model)
        #expect(banner?.message == "Update skrepkad to change these settings.")
        #expect(banner?.isDismissible == false)
    }

    @Test("an unreachable daemon's failure is the banner")
    func unreachable() {
        let failure = SyncFailure(message: "The Skrepka daemon is not running.", remedy: "start it")
        let model = PreferencesModel().applying(.loaded(.failed(failure)), now: now)
        #expect(PreferencesBanner.banner(model)?.message == failure.message)
        #expect(PreferencesBanner.banner(model)?.tone == .problem)
    }

    @Test("a change is in flight until its answer arrives, and the refreshed settings replace the old")
    func changeRoundTrip() {
        let patch = SettingsPatch(maximumItems: 100)
        let sent = Fixture.ready().sending(patch)
        #expect(sent.inFlight == [patch])

        let refreshed = Fixture.settings(maximumItems: 100)
        let answered = sent.applying(.changed(patch, .success(.succeeded()), refreshed: refreshed), now: now)
        #expect(answered.inFlight.isEmpty)
        #expect(answered.document?.retention.maximumItems == 100)
        #expect(answered.notice == nil)
    }

    @Test("a refused change says why, in a sentence")
    func refusedChange() {
        let patch = SettingsPatch(maximumItems: 5)
        let model = Fixture.ready().sending(patch)
            .applying(.changed(patch, .success(.refused("limit too small")), refreshed: nil), now: now)
        #expect(model.notice?.tone == .problem)
        #expect(model.notice?.message == "Limit too small.")
        #expect(model.document?.retention.maximumItems == 500)
    }

    @Test("only the answered one of two identical flips leaves the queue")
    func twoFlips() {
        let off = SettingsPatch(syncEnabled: false)
        let on = SettingsPatch(syncEnabled: true)
        let model = Fixture.ready().sending(off).sending(on)
            .applying(.changed(off, .success(.succeeded()), refreshed: nil), now: now)
        #expect(model.inFlight == [on])
        #expect(SharingSwitchState(model).isOn)
    }

    @Test("clearing reports its success, which then expires")
    func clearing() {
        let clearing = Fixture.ready().clearing()
        #expect(clearing.isClearing)
        #expect(HistoryPaneState(clearing).clearTitle == "Clearing…")
        #expect(!HistoryPaneState(clearing).isClearEnabled)

        let done = clearing.applying(
            .cleared(.success(.succeeded("cleared 3 entries")), refreshed: nil), now: now)
        #expect(!done.isClearing)
        #expect(done.notice?.message == "Cleared 3 entries.")
        #expect(done.notice?.tone == .success)
        #expect(done.expiring(now: now + 1).notice != nil)
        #expect(done.expiring(now: now + 60).notice == nil)
    }

    @Test("a failed clear stays on screen until dismissed")
    func failedClear() {
        let failure = SyncFailure(message: "The Skrepka daemon did not answer in time.")
        let done = Fixture.ready().clearing().applying(.cleared(.failure(failure), refreshed: nil), now: now)
        #expect(done.notice?.tone == .problem)
        #expect(done.expiring(now: now + 3600).notice != nil)
        #expect(done.dismissingNotice().notice == nil)
    }

    @Test("diagnostics arrive on their own, beside the settings")
    func diagnosis() {
        let document = Fixture.diagnostics()
        let model = Fixture.ready().applying(.diagnosed(.success(document)), now: now)
        #expect(model.diagnosis == .ready(document))
        #expect(model.document != nil)
    }
}
