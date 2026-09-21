import Foundation
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// Interface version 5: the file-size limit and automatic paste in the
/// settings, and the transfers a picker draws progress from.
@Suite("Version-5 settings and transfers")
struct TransfersAndLimitTests {
    @Test("the limits the CLI's target restates are the protocol's")
    func restatedConstantsAgree() {
        #expect(SettingsDocument.FileSync.ceiling == FileSyncLimit.ceiling)
        #expect(SettingsDocument.FileSync.choices == FileSyncLimit.choices)
        #expect(SettingsDocument.FileSync.default.maximumBytes == FileSyncLimit.defaultBytes)
    }

    @Test("a limit past the ceiling or below zero is refused, and every choice is accepted")
    func patchValidation() {
        #expect(SettingsPatch(maximumFileSyncBytes: -1).refusal?.contains("file size limit") == true)
        #expect(SettingsPatch(maximumFileSyncBytes: FileSyncLimit.ceiling + 1).refusal != nil)
        for choice in FileSyncLimit.choices {
            #expect(SettingsPatch(maximumFileSyncBytes: choice).refusal == nil)
        }
        #expect(!SettingsPatch(pasteAutomatically: false).isEmpty)
    }

    @Test("a settings document from a version-4 daemon reads the new members as their defaults")
    func olderDocumentDecodes() throws {
        let json = """
            {"history":{"entries":1,"images":0,"pinned":0},"protectedMarkers":[],\
            "retention":{"maximumAgeDays":30,"maximumItems":500},\
            "sync":{"isEnabled":true,"isLockedOff":false},"version":4}
            """
        let document = try SkrepkaDocumentCoding.decode(SettingsDocument.self, from: json)
        #expect(document.fileSync == .default)
        #expect(document.paste == .default)
    }

    @Test("a changed limit is saved, reported, and handed to sync at once")
    func applyingTheLimit() async throws {
        let options = DaemonSettingsMemberTests.options()
        let daemon = try Daemon(options: options, environment: [:])
        let changes = await daemon.historyChanges()

        let answer = await daemon.applySettings(
            SettingsPatch(maximumFileSyncBytes: 5 * FileSyncLimit.megabyte, pasteAutomatically: false))

        #expect(answer.ok)
        let document = await daemon.settingsDocument()
        #expect(document.fileSync.maximumBytes == 5 * FileSyncLimit.megabyte)
        #expect(!document.paste.isAutomatic)
        #expect(await daemon.fileSync.maximumBytes == 5 * FileSyncLimit.megabyte)
        // Every row's "over the limit" note may have changed with it.
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        let restarted = try Daemon(options: options, environment: [:])
        #expect(await restarted.fileSync.maximumBytes == 5 * FileSyncLimit.megabyte)
    }

    @Test("transfers read as the bus carries them, and nothing is in flight at rest")
    func transfersDocument() async throws {
        let daemon = try Daemon(options: DaemonSettingsMemberTests.options(), environment: [:])
        #expect(await daemon.transfersDocument().transfers.isEmpty)

        let document = Daemon.document([
            PayloadTransfer(contentHash: "b", receivedBytes: 10, totalBytes: 40)
        ])
        #expect(document.transfers == [.init(contentHash: "b", receivedBytes: 10, totalBytes: 40)])
        #expect(document.transfers.first?.fraction == 0.25)
        let json = try SkrepkaDocumentCoding.encode(document)
        #expect(try SkrepkaDocumentCoding.decode(TransfersDocument.self, from: json) == document)
    }

    @Test("a transfer the monitor reports reaches whoever follows the daemon's updates")
    func updatesFollowTheMonitor() async throws {
        let daemon = try Daemon(options: DaemonSettingsMemberTests.options(), environment: [:])
        var updates = await daemon.transferUpdates().makeAsyncIterator()
        #expect(await updates.next()?.isEmpty == true)
        let total = TransferMonitor.reportingThreshold * 2
        await daemon.transfers.begin("c", totalBytes: total)
        #expect(
            await updates.next() == [PayloadTransfer(contentHash: "c", receivedBytes: 0, totalBytes: total)])
    }
}
