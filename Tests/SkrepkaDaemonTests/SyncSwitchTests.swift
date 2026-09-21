import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaDaemon

/// `SetSettings(syncEnabled:)` at runtime: the network half comes up and goes
/// down without the daemon restarting, and the choice is what the next start
/// reads.
///
/// Needs no mDNS responder: discovery that finds none is reported and stepped
/// over, and what is asserted is the listener and the runtime.
@Suite("Turning sync on and off at runtime")
struct SyncSwitchTests {
    @Test("off stops the listener and the runtime; on brings them back")
    func switchesAtRuntime() async throws {
        let options = DaemonSettingsMemberTests.options(syncLockedOff: false)
        try DaemonSettingsFile(url: options.settingsURL(environment: [:]))
            .save(DaemonSettings.default.applying(SettingsPatch(syncEnabled: false)))
        let daemon = try Daemon(options: options, environment: [:])
        #expect(
            await daemon.settingsDocument().sync
                == SettingsDocument.Sync(isEnabled: false, isLockedOff: false))

        let on = await daemon.applySettings(SettingsPatch(syncEnabled: true))
        #expect(on.ok, "\(on.detail)")
        #expect(await daemon.runtime != nil)
        #expect(await daemon.syncServer != nil)
        #expect(await daemon.settingsDocument().sync.isEnabled)

        let off = await daemon.applySettings(SettingsPatch(syncEnabled: false))
        #expect(off.ok, "\(off.detail)")
        #expect(await daemon.runtime == nil)
        #expect(await daemon.syncServer == nil)
        #expect(await daemon.pairingServer == nil)
        #expect(await daemon.isPublished == false)

        let reread = DaemonSettingsFile(url: options.settingsURL(environment: [:])).read()
        #expect(reread.0.sync.enabled == false)
        await daemon.stop()
    }
}
