import Foundation
import SkrepkaCore
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// `Settings` and `SetSettings`: what the Settings window and `skrepka config`
/// read and change, pinned to the file and the store they act on.
@Suite("Settings members")
struct DaemonSettingsMemberTests {
    static func options(syncLockedOff: Bool = true) -> DaemonOptions {
        var options = DaemonOptions()
        options.syncEnabled = !syncLockedOff
        let root = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-settings-member-\(UUID().uuidString)", directoryHint: .isDirectory)
        options.dataDirectory = root
        options.configURL = root.appending(path: "config.json", directoryHint: .notDirectory)
        return options
    }

    static func item(_ text: String, age: TimeInterval) -> ClipItem {
        ClipItem(
            kind: .text,
            text: text,
            payload: ClipPayload(representations: ["public.utf8-plain-text": Data(text.utf8)]),
            createdAt: Date().addingTimeInterval(-age)
        )
    }

    @Test("with no file the document is today's defaults, and --no-sync locks sync off")
    func defaultsAndLock() async throws {
        let daemon = try Daemon(options: Self.options(), environment: [:])
        let document = await daemon.settingsDocument()
        #expect(document.version == SkrepkaInterface.version)
        #expect(document.retention == SettingsDocument.Retention(maximumItems: 500, maximumAgeDays: 30))
        #expect(document.sync == SettingsDocument.Sync(isEnabled: false, isLockedOff: true))
        #expect(document.history == SettingsDocument.HistoryCounts(entries: 0, pinned: 0, images: 0))
        #expect(document.protectedMarkers.first == "x-kde-passwordManagerHint = secret")
        #expect(document.protectedMarkers.contains("org.nspasteboard.TransientType"))
    }

    @Test("a lowered cap is saved, evicts at once, writes no tombstones, and announces it")
    func loweredCapEvicts() async throws {
        let options = Self.options()
        let daemon = try Daemon(options: options, environment: [:])
        for index in 0..<4 {
            _ = await daemon.historyStore.capture(Self.item("entry \(index)", age: Double(10 - index)))
        }
        let changes = await daemon.historyChanges()

        let answer = await daemon.applySettings(SettingsPatch(maximumItems: 1))

        #expect(answer.ok)
        #expect(try await daemon.historyStore.summaries().map(\.text) == ["entry 3"])
        #expect(try await daemon.historyStore.tombstones(since: nil).isEmpty)
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        let saved = DaemonSettingsFile(url: options.settingsURL(environment: [:])).read()
        #expect(saved.1 == .loaded)
        #expect(saved.0.retention == DaemonSettings.Retention(maximumItems: 1, maximumAgeDays: 30))
        #expect(await daemon.settingsDocument().history.entries == 1)
    }

    @Test("settings survive a restart and build the store's policy")
    func settingsSurviveARestart() async throws {
        let options = Self.options()
        let first = try Daemon(options: options, environment: [:])
        #expect(await first.applySettings(SettingsPatch(maximumItems: 0, maximumAgeDays: 7)).ok)

        let second = try Daemon(options: options, environment: [:])
        let retention = await second.settingsDocument().retention
        #expect(retention == SettingsDocument.Retention(maximumItems: 0, maximumAgeDays: 7))
        let policy = await second.historyStore.retentionPolicy
        #expect(policy == RetentionPolicy(maximumItems: nil, maximumAge: 7 * 86_400))
    }

    @Test("an out-of-range limit is refused and changes nothing")
    func outOfRangeIsRefused() async throws {
        let options = Self.options()
        let daemon = try Daemon(options: options, environment: [:])
        let answer = await daemon.applySettings(SettingsPatch(maximumAgeDays: -1))
        #expect(answer.ok == false)
        #expect(await daemon.settingsDocument().retention.maximumAgeDays == 30)
        #expect(FileManager.default.fileExists(atPath: options.settingsURL(environment: [:]).path) == false)
    }

    @Test("--no-sync refuses a request to turn sync on")
    func lockedSyncCannotBeTurnedOn() async throws {
        let daemon = try Daemon(options: Self.options(), environment: [:])
        let answer = await daemon.applySettings(SettingsPatch(syncEnabled: true))
        #expect(answer.ok == false)
        #expect(answer.detail.contains("--no-sync"))
    }

    @Test("the sweep ages out what is past the age limit")
    func sweepAgesOut() async throws {
        let daemon = try Daemon(options: Self.options(), environment: [:])
        _ = await daemon.historyStore.capture(Self.item("fresh", age: 60))
        #expect(await daemon.applySettings(SettingsPatch(maximumAgeDays: 1)).ok)
        // A minute old passes a one-day limit today; two days from now it
        // does not, with nothing captured in between.
        let evicted = try await daemon.historyStore.sweepRetention(now: Date().addingTimeInterval(2 * 86_400))
        #expect(evicted == 1)
        #expect(await daemon.settingsDocument().history.entries == 0)
    }
}
