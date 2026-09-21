import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

@Suite("Settings: the preferences calls")
struct PreferencesJobsTests {
    @Test("a daemon older than version 4 is asked its version and nothing it cannot answer")
    func oldDaemon() async {
        let daemon = FakePreferencesDaemon(version: 3)
        let event = await PreferencesJobs.load { daemon }
        #expect(event == .loaded(.unsupported(3)))
        #expect(await daemon.calls == ["interfaceVersion"])
    }

    @Test("a current daemon's settings are read")
    func currentDaemon() async {
        let daemon = FakePreferencesDaemon()
        let event = await PreferencesJobs.load { daemon }
        #expect(event == .loaded(.ready(PreferencesFixtures.settings())))
    }

    @Test("an unreachable daemon is a failure, not a crash")
    func unreachable() async {
        let event = await PreferencesJobs.load { throw SyncFailure(message: "no bus") }
        #expect(event == .loaded(.failed(SyncFailure(message: "no bus"))))
    }

    @Test("a change is followed by a fresh read of the settings")
    func change() async {
        let daemon = FakePreferencesDaemon()
        let patch = SettingsPatch(syncEnabled: false)
        let event = await PreferencesJobs.change(patch, { daemon })
        #expect(await daemon.calls == ["setSettings", "settings"])
        guard case .changed(patch, .success(let answer), let refreshed) = event else {
            Issue.record("expected a change, got \(event)")
            return
        }
        #expect(answer.ok)
        #expect(refreshed?.sync.isEnabled == false)
    }

    @Test("clear passes on the choice, then reads the new counts")
    func clear() async {
        let daemon = FakePreferencesDaemon()
        _ = await PreferencesJobs.clear(keepingPinned: true, { daemon })
        #expect(await daemon.calls == ["clear true", "settings"])
    }

    @Test("a job queued on the link runs after what was queued before it")
    func jobOrder() async {
        let sync = FakeSyncDaemon(document: SyncFixtures.document([SyncFixtures.paired()]))
        let log = EventLog()
        let link = await DaemonLinkTests.link(sync, log)
        await sync.hold("syncNow")
        link.perform(.syncNow)
        let ran = RanFlag()
        link.run { await ran.set() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await ran.value == false)

        await sync.release("syncNow")
        for _ in 0..<500 {
            if await ran.value { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await ran.value)
        await link.shutdown()
    }
}

/// Whether a queued job has run.
private actor RanFlag {
    private(set) var value = false

    func set() {
        value = true
    }
}
