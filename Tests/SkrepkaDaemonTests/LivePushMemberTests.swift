import Foundation
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// `SetLivePush`, and the two `PeerDocument` fields a settings window draws
/// its switch from.
///
/// The daemon stored a per-peer choice from Phase 6 on, and nothing on the bus
/// could set it: the only way to change it on Linux was to edit the trust file
/// by hand. These pin the member to the store and the document to the setting
/// the push loop actually uses.
@Suite("Live push per device, over the bus")
struct LivePushMemberTests {
    static func daemon() throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-live-push-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:])
    }

    static func peer(seed: UInt8) -> PairedPeer {
        PairedPeer(
            certificateDER: Data(repeating: seed, count: 32),
            deviceName: "peer-\(seed)",
            platform: .macos,
            pairedAt: Date()
        )
    }

    @Test("a choice is recorded against the device it names, and the push gate follows it")
    func choiceIsStoredAndApplied() async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 11)
        try await daemon.trust.savePairedPeer(peer)

        let on = await daemon.setLivePush(device: peer.deviceID.fingerprint, choice: .on)
        let storedOn = try await daemon.trust.livePushChoice(for: peer.deviceID)
        let pushesWhenOn = await daemon.isLivePushOn(for: peer.deviceID)
        #expect(on.ok)
        #expect(storedOn == .on)
        #expect(pushesWhenOn)

        let off = await daemon.setLivePush(device: peer.deviceID.hex, choice: .off)
        let pushesWhenOff = await daemon.isLivePushOn(for: peer.deviceID)
        #expect(off.ok)
        #expect(off.subject == peer.deviceID.fingerprint)
        #expect(pushesWhenOff == false)
    }

    @Test(
        "a selector that names no single paired device changes nothing",
        arguments: ["", "  ", "no-such-device"]
    )
    func unknownDeviceIsRefused(_ selector: String) async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 12)
        try await daemon.trust.savePairedPeer(peer)

        let answer = await daemon.setLivePush(device: selector, choice: .off)
        let stored = try await daemon.trust.livePushChoice(for: peer.deviceID)

        #expect(answer.ok == false)
        #expect(stored == .followsPlatformDefault)
    }

    /// Before its link has connected this run, the daemon does not know what a
    /// paired peer runs, so the default is the unrecognised-platform one — and
    /// the document has to say that rather than the platform the pairing
    /// recorded, or the row explains a default the push loop is not applying.
    @Test("the peers document carries the choice and the default the push gate resolved")
    func documentCarriesTheResolvedSetting() async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 13)
        try await daemon.trust.savePairedPeer(peer)

        let first = await daemon.peersDocument()
        let before = try #require(first.peers.first)
        #expect(before.livePushChoice == PeerDocument.LivePushChoiceName.followsPlatformDefault)
        #expect(before.livePushDefault == PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform)
        #expect(before.livePush == false)

        _ = await daemon.setLivePush(device: peer.deviceID.fingerprint, choice: .on)
        let second = await daemon.peersDocument()
        let after = try #require(second.peers.first)
        #expect(after.livePushChoice == PeerDocument.LivePushChoiceName.on)
        #expect(after.livePush)
    }

    /// `SkrepkaIPC` cannot import `SkrepkaSync`, so its names are a second
    /// spelling of the sync core's; this is what keeps the two one list.
    @Test("the bus names are exactly the sync core's cases")
    func namesMatchTheSyncModel() {
        let choices: Set = [
            PeerDocument.LivePushChoiceName.followsPlatformDefault,
            PeerDocument.LivePushChoiceName.on,
            PeerDocument.LivePushChoiceName.off,
        ]
        #expect(choices == Set(LivePushChoice.allCases.map(\.rawValue)))

        let defaults: Set = [
            PeerDocument.LivePushDefaultName.on,
            PeerDocument.LivePushDefaultName.offBetweenAppleDevices,
            PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform,
        ]
        #expect(defaults == Set(LivePushDefault.allCases.map(Daemon.wireName)))
    }

    @Test("a peer from a version-1 daemon still decodes, with no live-push detail")
    func olderDocumentDecodes() throws {
        let json = """
            {"deviceID":"ab","fingerprint":"AB","isAcceptingPairing":false,"isPaired":true,\
            "isSighted":true,"linkState":"synced","livePush":true,"name":"mac","platform":"macos"}
            """
        let decoded = try SkrepkaDocumentCoding.decoder().decode(PeerDocument.self, from: Data(json.utf8))
        #expect(decoded.livePush)
        #expect(decoded.livePushChoice == nil)
        #expect(decoded.livePushDefault == nil)
    }
}
