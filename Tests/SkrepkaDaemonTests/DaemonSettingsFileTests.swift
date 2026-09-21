import Foundation
import SkrepkaCore
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// `config.json`: what an absent, a good and a broken file each turn into.
///
/// The broken cases carry the weight. The daemon must never refuse to start
/// over this file, and must never silently overwrite a file it could not read.
@Suite("The settings file")
struct DaemonSettingsFileTests {
    static func file() -> DaemonSettingsFile {
        DaemonSettingsFile(
            url: FileManager.default.temporaryDirectory
                .appending(path: "skrepka-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
                .appending(path: "config.json", directoryHint: .notDirectory))
    }

    static func write(_ text: String, to file: DaemonSettingsFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    @Test("no file is today's behaviour: 500 entries, 30 days, sync on")
    func absentFileIsTheDefaults() {
        let (settings, outcome) = Self.file().read()
        #expect(outcome == .absent)
        #expect(settings == .default)
        #expect(settings.retention == DaemonSettings.Retention(maximumItems: 500, maximumAgeDays: 30))
        #expect(settings.sync.enabled)
        #expect(settings.retentionPolicy == RetentionPolicy.default)
    }

    @Test("what is saved is what is read back")
    func saveRoundTrips() throws {
        let file = Self.file()
        let changed = DaemonSettings.default.applying(
            SettingsPatch(maximumItems: 0, maximumAgeDays: 7, syncEnabled: false))
        try file.save(changed)

        let (read, outcome) = file.read()
        #expect(outcome == .loaded)
        #expect(read == changed)
        #expect(read.retentionPolicy == RetentionPolicy(maximumItems: nil, maximumAge: 7 * 24 * 60 * 60))
        // No temporary file is left beside it.
        let directory = file.url.deletingLastPathComponent().path
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        #expect(names == ["config.json"])
    }

    @Test("the documented shape reads as written")
    func documentedShapeReads() throws {
        let file = Self.file()
        try Self.write(
            #"{"version":1,"retention":{"maximumItems":250,"maximumAgeDays":0},"sync":{"enabled":false}}"#,
            to: file)
        let (read, outcome) = file.read()
        #expect(outcome == .loaded)
        #expect(read.retention == DaemonSettings.Retention(maximumItems: 250, maximumAgeDays: 0))
        #expect(read.sync.enabled == false)
    }

    @Test(
        "a file that will not parse, or holds a value no client could set, is moved aside",
        arguments: [
            "{not json",
            #"{"version":1}"#,
            #"{"version":0,"retention":{"maximumItems":5,"maximumAgeDays":5},"sync":{"enabled":true}}"#,
            #"{"version":1,"retention":{"maximumItems":-1,"maximumAgeDays":5},"sync":{"enabled":true}}"#,
            #"{"version":1,"retention":{"maximumItems":5,"maximumAgeDays":99999},"sync":{"enabled":true}}"#,
        ]
    )
    func brokenFileIsQuarantined(_ text: String) throws {
        let file = Self.file()
        try Self.write(text, to: file)

        let (read, outcome) = file.read()
        guard case .quarantined = outcome else {
            Issue.record("expected the file to be quarantined, got \(outcome)")
            return
        }
        #expect(read == .default)
        #expect(FileManager.default.fileExists(atPath: file.url.path) == false)
        let kept = try String(contentsOf: file.quarantineURL, encoding: .utf8)
        #expect(kept == text)
    }

    /// A newer daemon's file carries keys this one has never heard of. It is
    /// read, not quarantined — the same additive rule the bus documents follow.
    @Test("a newer version with extra keys is read, not thrown away")
    func newerVersionIsRead() throws {
        let file = Self.file()
        try Self.write(
            #"{"version":2,"retention":{"maximumItems":100,"maximumAgeDays":7},"sync":{"enabled":true},"theme":"dark"}"#,
            to: file)
        let (read, outcome) = file.read()
        #expect(outcome == .loaded)
        #expect(read.retention.maximumItems == 100)
    }

    @Test("a save stamps the version this build writes")
    func saveStampsTheCurrentVersion() {
        let patched = DaemonSettings(
            version: 2, retention: .init(maximumItems: 1, maximumAgeDays: 1), sync: .init(enabled: true)
        ).applying(SettingsPatch(maximumItems: 5))
        #expect(patched.version == DaemonSettings.currentVersion)
        #expect(patched.retention == DaemonSettings.Retention(maximumItems: 5, maximumAgeDays: 1))
    }
}

/// The range rule the CLI and the daemon share.
@Suite("Settings patch validation")
struct SettingsPatchValidationTests {
    @Test("in range, including 0 for no limit and the limits themselves")
    func inRangeIsAccepted() {
        #expect(SettingsPatch().refusal == nil)
        #expect(SettingsPatch(maximumItems: 0, maximumAgeDays: 0).refusal == nil)
        #expect(
            SettingsPatch(
                maximumItems: SettingsPatch.maximumItemsLimit,
                maximumAgeDays: SettingsPatch.maximumAgeDaysLimit
            ).refusal == nil)
        #expect(SettingsPatch(syncEnabled: false).refusal == nil)
    }

    @Test("negative or past the limit is refused, with the setting named")
    func outOfRangeIsRefused() {
        #expect(SettingsPatch(maximumItems: -1).refusal?.contains("item limit") == true)
        #expect(SettingsPatch(maximumItems: SettingsPatch.maximumItemsLimit + 1).refusal != nil)
        #expect(SettingsPatch(maximumAgeDays: -3).refusal?.contains("age limit") == true)
        #expect(SettingsPatch(maximumAgeDays: SettingsPatch.maximumAgeDaysLimit + 1).refusal != nil)
    }
}
