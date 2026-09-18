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
    /// - Parameter peers: A store to use for the paired half, where a test
    ///   needs one that fails; the daemon's own SQLite store otherwise.
    static func daemon(peers: (any PairedDeviceStoring)? = nil) throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-live-push-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:], peers: peers)
    }

    static func peer(seed: UInt8, platform: PeerPlatform = .macos) -> PairedPeer {
        PairedPeer(
            certificateDER: Data(repeating: seed, count: 32),
            deviceName: "peer-\(seed)",
            platform: platform,
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

    /// A paired peer's platform is its link's: unknown with no link — sync is
    /// off here — then what the pairing recorded, then what its `hello` says.
    /// The document states the default for whichever applies, and the push
    /// gate reads the same one, so the row never explains a default the push
    /// loop is not applying.
    @Test("the peers document carries the choice and the default the push gate resolved")
    func documentCarriesTheResolvedSetting() async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 13)
        try await daemon.trust.savePairedPeer(peer)

        let untracked = try #require(await daemon.peersDocument().peers.first)
        #expect(untracked.livePushChoice == PeerDocument.LivePushChoiceName.followsPlatformDefault)
        #expect(untracked.livePushDefault == PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform)
        #expect(untracked.livePush == false)

        // What a link does as it starts. A Mac that is asleep is known by the
        // platform its pairing recorded, so it is drawn on — as the push gate
        // treats it the moment it connects.
        await daemon.beginTracking(peer)
        let tracked = try #require(await daemon.peersDocument().peers.first)
        #expect(tracked.livePushDefault == PeerDocument.LivePushDefaultName.on)
        #expect(tracked.livePush)
        #expect(await daemon.isLivePushOn(for: peer.deviceID))

        // Its `hello` outranks the record: here, a platform this build does not know.
        await daemon.apply(.connected(name: "peer-13", platform: .unknown), to: peer.deviceID)
        let greeted = try #require(await daemon.peersDocument().peers.first)
        #expect(greeted.livePushDefault == PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform)
        #expect(await daemon.isLivePushOn(for: peer.deviceID) == false)

        _ = await daemon.setLivePush(device: peer.deviceID.fingerprint, choice: .on)
        let chosen = try #require(await daemon.peersDocument().peers.first)
        #expect(chosen.livePushChoice == PeerDocument.LivePushChoiceName.on)
        #expect(chosen.livePush)
    }

    /// Two Linux machines push by default, so a store that cannot say whether
    /// the user turned a peer off must not be read as "follows the default".
    @Test("a choice that cannot be read holds live push off rather than falling back to the default")
    func unreadableChoiceFailsClosed() async throws {
        let peer = Self.peer(seed: 14, platform: .linux)

        let readable = RecordingPeerStore()
        let control = try Self.daemon(peers: readable)
        try await readable.savePairedPeer(peer)
        await control.beginTracking(peer)
        #expect(await control.isLivePushOn(for: peer.deviceID))

        let unreadable = RecordingPeerStore(failsOnChoiceRead: true)
        let daemon = try Self.daemon(peers: unreadable)
        try await unreadable.savePairedPeer(peer)
        await daemon.beginTracking(peer)
        #expect(await daemon.isLivePushOn(for: peer.deviceID) == false)

        let document = try #require(await daemon.peersDocument().peers.first)
        #expect(document.livePush == false)
        #expect(document.livePushChoice == PeerDocument.LivePushChoiceName.off)
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
