import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

@Suite("The file-size setting")
struct FileSyncSettingTests {
    private static let megabyte = FileSyncLimit.megabyte

    @Test("Limits are named the way a pane lists them")
    func labels() {
        #expect(FileSyncLimitLabel.text(for: 0) == "Off")
        #expect(FileSyncLimitLabel.text(for: 5 * Self.megabyte) == "5 MB")
        #expect(FileSyncLimitLabel.text(for: FileSyncLimit.ceiling) == "32 MB")
        #expect(FileSyncLimitLabel.text(for: Self.megabyte * 25 / 2) == "12.5 MB")
    }

    @Test("A limit that is not a choice is slotted in among them, in order")
    func choicesIncludeTheCurrentValue() {
        #expect(FileSyncLimitLabel.choices(including: 5 * Self.megabyte) == FileSyncLimit.choices)
        let odd = 3 * Self.megabyte
        let choices = FileSyncLimitLabel.choices(including: odd)
        #expect(choices.contains(odd))
        #expect(choices == choices.sorted())
        #expect(choices.count == FileSyncLimit.choices.count + 1)
    }

    @MainActor
    @Test("The preference defaults to the ceiling, persists, and clamps what it is given")
    func preference() throws {
        let suite = "skrepka.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = Preferences(defaults: defaults)
        #expect(preferences.maximumFileSyncBytes == FileSyncLimit.ceiling)

        preferences.maximumFileSyncBytes = 5 * Self.megabyte
        #expect(Preferences(defaults: defaults).maximumFileSyncBytes == 5 * Self.megabyte)

        preferences.maximumFileSyncBytes = .max
        #expect(preferences.maximumFileSyncBytes == FileSyncLimit.ceiling)
        #expect(Preferences(defaults: defaults).maximumFileSyncBytes == FileSyncLimit.ceiling)

        defaults.set(-4, forKey: "maximumFileSyncBytes")
        #expect(Preferences(defaults: defaults).maximumFileSyncBytes == 0)
    }

    @MainActor
    @Test("Progress is resolved to rows once per snapshot, and a vanished row is left out")
    func transferProgress() {
        let id = UUID()
        let progress = TransferProgress()
        progress.apply(
            [
                PayloadTransfer(contentHash: "known", receivedBytes: 1, totalBytes: 4),
                PayloadTransfer(contentHash: "gone", receivedBytes: 1, totalBytes: 4),
            ],
            resolve: { $0 == "known" ? id : nil }
        )
        #expect(progress.fractions == [id: 0.25])
        #expect(progress.fraction(for: id) == 0.25)
        progress.apply([], resolve: { _ in id })
        #expect(progress.fraction(for: id) == nil)
    }
}
