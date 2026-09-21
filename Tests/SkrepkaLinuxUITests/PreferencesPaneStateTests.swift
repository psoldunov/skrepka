import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

@Suite("Settings: History, Privacy and Sharing as drawn")
struct PreferencesPaneStateTests {
    typealias Fixture = PreferencesFixtures

    @Test("the retention choices are the Mac's, with Unlimited and Never last")
    func macChoices() {
        let state = HistoryPaneState(Fixture.ready())
        #expect(
            state.keepAtMost.labels == [
                "100 items", "250 items", "500 items", "1000 items", "5000 items", "Unlimited",
            ])
        #expect(state.keepAtMost.selected == 2)
        #expect(state.discardAfter.labels == ["1 day", "7 days", "30 days", "90 days", "1 year", "Never"])
        #expect(state.discardAfter.selected == 2)
        #expect(state.entries == "42")
        #expect(state.isEditable)
    }

    @Test("a limit set from the command line joins the choices, in order, and is selected")
    func foreignLimit() {
        let state = HistoryPaneState(Fixture.ready(Fixture.settings(maximumItems: 300, maximumAgeDays: 0)))
        #expect(state.keepAtMost.values == [100, 250, 300, 500, 1000, 5000, 0])
        #expect(state.keepAtMost.selected == 2)
        #expect(state.discardAfter.selected == state.discardAfter.values.count - 1)
    }

    @Test("a choice on its way shows at once")
    func inFlightChoice() {
        let state = HistoryPaneState(Fixture.ready().sending(SettingsPatch(maximumAgeDays: 365)))
        #expect(state.discardAfter.labels[state.discardAfter.selected] == "1 year")
    }

    @Test("before the daemon answers, the figures and drop-downs claim nothing")
    func unknown() {
        let state = HistoryPaneState(PreferencesModel())
        #expect(state.entries == "—")
        #expect(state.keepAtMost.labels == ["—"])
        #expect(state.keepAtMost.values.isEmpty)
        #expect(!state.isEditable)
        #expect(!state.isClearEnabled)
    }

    @Test("sharing is off and disabled, saying why, when the daemon was started with --no-sync")
    func lockedOff() {
        let state = SharingSwitchState(Fixture.ready(Fixture.settings(syncEnabled: true, isLockedOff: true)))
        #expect(!state.isOn)
        #expect(!state.isEnabled)
        #expect(state.subtitle.contains("--no-sync"))
    }

    @Test("sharing cannot be changed from a daemon too old to have the setting")
    func sharingUnsupported() {
        let state = SharingSwitchState(
            PreferencesModel().applying(.loaded(.unsupported(3)), now: SyncFixtures.now))
        #expect(!state.isEnabled)
        #expect(state.subtitle.contains("Update skrepkad"))
    }

    @Test("sharing follows the daemon")
    func sharingFollows() {
        #expect(SharingSwitchState(Fixture.ready(Fixture.settings(syncEnabled: false))).isOn == false)
        #expect(SharingSwitchState(Fixture.ready()).isOn)
        #expect(SharingSwitchState(Fixture.ready()).isEnabled)
    }

    @Test("privacy lists the daemon's markers, and says why when it cannot")
    func privacy() {
        let ready = PrivacyPaneState(Fixture.ready())
        #expect(ready.markers == ["x-kde-passwordManagerHint = secret"])
        #expect(ready.markersPlaceholder == nil)
        let old = PrivacyPaneState(
            PreferencesModel().applying(.loaded(.unsupported(3)), now: SyncFixtures.now))
        #expect(old.markers.isEmpty)
        #expect(old.markersPlaceholder != nil)
        #expect(old.banner != nil)
    }
}
