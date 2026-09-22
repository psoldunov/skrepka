import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxUI

@Suite("Settings: the file-size limit as drawn")
struct FileLimitStateTests {
    typealias Fixture = PreferencesFixtures
    private static let megabyte = FileSyncLimit.megabyte

    private static func settings(fileLimit: Int) -> SettingsDocument {
        let base = Fixture.settings()
        return SettingsDocument(
            retention: base.retention,
            sync: base.sync,
            history: base.history,
            protectedMarkers: base.protectedMarkers,
            fileSync: SettingsDocument.FileSync(maximumBytes: fileLimit)
        )
    }

    @Test("the choices run from Off to 32 MB, with the one in force selected")
    func choices() {
        let state = FileLimitState(Fixture.ready(Self.settings(fileLimit: 10 * Self.megabyte)))
        #expect(state.choice.labels == ["Off", "1 MB", "5 MB", "10 MB", "20 MB", "32 MB"])
        #expect(state.choice.labels[state.choice.selected] == "10 MB")
        #expect(state.isEnabled)
    }

    @Test("a limit set from the command line joins the choices and is selected")
    func foreignLimit() {
        let state = FileLimitState(Fixture.ready(Self.settings(fileLimit: 3 * Self.megabyte)))
        #expect(state.choice.values.contains(3 * Self.megabyte))
        #expect(state.choice.values[state.choice.selected] == 3 * Self.megabyte)
        #expect(state.choice.values == state.choice.values.sorted())
    }

    @Test("a choice on its way shows at once")
    func inFlight() {
        let model = Fixture.ready().sending(SettingsPatch(maximumFileSyncBytes: 0))
        let state = FileLimitState(model)
        #expect(state.choice.labels[state.choice.selected] == "Off")
    }

    @Test("a daemon older than version 5 shows the default but cannot be changed from here")
    func olderDaemon() {
        let base = Self.settings(fileLimit: FileSyncLimit.ceiling)
        let older = SettingsDocument(
            retention: base.retention,
            sync: base.sync,
            history: base.history,
            protectedMarkers: base.protectedMarkers,
            version: 4
        )
        let state = FileLimitState(Fixture.ready(older))
        #expect(state.choice.labels[state.choice.selected] == "32 MB")
        #expect(!state.isEnabled)
    }

    @Test("before the daemon answers, the drop-down claims nothing and cannot be changed")
    func unknown() {
        let state = FileLimitState(PreferencesModel())
        #expect(state.choice.values.isEmpty)
        #expect(!state.isEnabled)
    }

    @Test("a transfer snapshot becomes fractions by content hash")
    func fractions() {
        let document = TransfersDocument(transfers: [
            .init(contentHash: "a", receivedBytes: 1, totalBytes: 4),
            .init(contentHash: "b", receivedBytes: 9, totalBytes: 3),
        ])
        #expect(PickerLink.fractions(document) == ["a": 0.25, "b": 1])
    }
}
