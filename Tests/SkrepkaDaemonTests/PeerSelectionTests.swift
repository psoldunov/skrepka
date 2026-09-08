import Foundation
// For `ActionDocument.ok` / `.detail`. Swift 6's MemberImportVisibility wants
// the module that declares a member imported here, not merely somewhere in the
// target.
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// A blank device selector must select nothing.
///
/// `hasPrefix("")` is true of every string, so an empty fingerprint used to
/// match the whole paired set and the whole sighted set: `skrepka unpair ""`
/// forgot the only paired peer, and `skrepka pair --peer ""` dialled whichever
/// device happened to be visible. Both selectors are asserted here rather than
/// in the CLI, because the daemon is the authority — anything on the session
/// bus can call these members.
@Suite("A blank fingerprint selects nothing")
struct PeerSelectionTests {
    static func daemon() throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    static func sighting(_ deviceID: SyncDeviceID) -> Sighting {
        Sighting(
            peer: DiscoveredPeer(
                instanceName: "peer-\(deviceID.hex.prefix(4))",
                serviceType: ServiceDescriptor.serviceType,
                domain: "local.",
                interfaceIndex: nil,
                advertisement: .unread
            ),
            advertisement: PeerAdvertisement(
                deviceID: deviceID,
                displayName: "a peer",
                platform: .macos,
                protocolVersion: .current,
                pairingPort: 5555
            )
        )
    }

    // MARK: - Dialling

    @Test(
        "no sighting matches a blank selector",
        arguments: ["", " ", "\t", "\n", "   \n "]
    )
    func aBlankSelectorMatchesNoSighting(_ blank: String) throws {
        let deviceID = try #require(SyncDeviceID(hex: String(repeating: "ab", count: 32)))
        let sighted = [deviceID: Self.sighting(deviceID)]

        #expect(Daemon.sighting(matching: blank, in: sighted) == nil)
        // And the same table still resolves a real prefix, so the guard has not
        // simply broken matching.
        #expect(Daemon.sighting(matching: "abab", in: sighted) != nil)
    }

    @Test("a blank selector is refused before the network is consulted")
    func aBlankSelectorCannotBeDialled() async throws {
        let daemon = try Self.daemon()
        await #expect(throws: PairError.self) {
            _ = try await daemon.pair(withFingerprint: "  ")
        }
    }

    // MARK: - Unpairing

    @Test(
        "unpairing with a blank selector forgets nothing",
        arguments: ["", " ", "\n"]
    )
    func aBlankSelectorForgetsNothing(_ blank: String) async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 7)
        try await daemon.trust.savePairedPeer(peer)

        let answer = await daemon.unpair(fingerprint: blank)

        #expect(answer.ok == false)
        #expect(answer.detail == Daemon.blankSelectorDetail)
        // The point of the whole test: the peer is still paired.
        let remaining = try await daemon.trust.pairedPeers()
        #expect(remaining.count == 1)
    }

    /// The other half — the guard refuses blanks and nothing else.
    @Test("a real fingerprint still forgets the device it names")
    func aRealSelectorStillWorks() async throws {
        let daemon = try Self.daemon()
        let peer = Self.peer(seed: 8)
        try await daemon.trust.savePairedPeer(peer)

        let answer = await daemon.unpair(fingerprint: peer.deviceID.fingerprint)

        #expect(answer.ok)
        let remaining = try await daemon.trust.pairedPeers()
        #expect(remaining.isEmpty)
    }
}
