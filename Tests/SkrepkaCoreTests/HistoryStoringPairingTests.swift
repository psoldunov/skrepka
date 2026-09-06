import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// The paired-peer surface of ``HistoryStoringTests``.
///
/// Not part of `HistoryStoring` — a transport never asks a history store who is
/// paired — but it is the other half of what each engine persists, and the
/// anti-downgrade mark is the one column where an engine getting `NULL` handling
/// wrong is a security bug rather than a display bug.
extension HistoryStoringTests {
    @Test("A paired peer round trips through the store", arguments: HistoryStoreEngine.all)
    func pairedPeerRoundTrips(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let peer = EngineFixtures.peer(named: "Peer")
        try await store.savePairedPeer(peer)

        #expect(try await store.pairedPeers() == [peer])
        #expect(try await store.pairedPeer(peer.deviceID) == peer)

        try await store.forgetPairedPeer(peer.deviceID)
        #expect(try await store.pairedPeers().isEmpty)
        #expect(try await store.pairedPeer(peer.deviceID) == nil)
    }

    @Test("The protocol high-water mark only ever rises", arguments: HistoryStoreEngine.all)
    func protocolMarkOnlyRises(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let peer = EngineFixtures.peer(named: "Peer")
        try await store.savePairedPeer(peer)

        // Never connected yet, which is not the same as "spoke v1".
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == nil)

        let v2 = ProtocolVersion(rawValue: 2)
        try await store.recordProtocolVersion(v2, for: peer.deviceID)
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == v2)

        // A peer that once spoke v2 and now claims v1 is a downgrade, and the mark
        // that catches it must not move.
        try await store.recordProtocolVersion(.v1, for: peer.deviceID)
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == v2)

        // Re-pairing must not reset it either, or forcing one re-pair would be
        // enough to erase the mark.
        try await store.savePairedPeer(peer.renamed("Peer, renamed"))
        #expect(try await store.pairedPeer(peer.deviceID)?.deviceName == "Peer, renamed")
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == v2)

        // Forgetting a peer forgets its mark: a forgotten device is a stranger
        // again, which is what makes re-pairing mean anything.
        try await store.forgetPairedPeer(peer.deviceID)
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == nil)
    }

    @Test("A first connection is recorded, not lost to a NULL", arguments: HistoryStoreEngine.all)
    func theFirstVersionSeenIsRecorded(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let peer = EngineFixtures.peer(named: "Peer")
        try await store.savePairedPeer(peer)

        // `NULL < 1` is `NULL` in SQL, so a raise written as a bare inequality
        // would silently never record a peer's first connection — and the
        // downgrade check would then have nothing to compare against forever.
        try await store.recordProtocolVersion(.v1, for: peer.deviceID)
        #expect(try await store.highestProtocolVersion(for: peer.deviceID) == .v1)
    }

    @Test("An unpaired peer's version is neither recorded nor invented", arguments: HistoryStoreEngine.all)
    func recordingAVersionDoesNotCreateAPeer(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let stranger = EngineFixtures.peer(named: "Stranger")

        try await store.recordProtocolVersion(.v1, for: stranger.deviceID)

        #expect(try await store.pairedPeers().isEmpty)
        #expect(try await store.highestProtocolVersion(for: stranger.deviceID) == nil)
    }

    @Test("Paired peers come back oldest pairing first", arguments: HistoryStoreEngine.all)
    func pairedPeersAreOrderedByPairingDate(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let first = PairedPeer(
            certificateDER: Data("certificate-of-first".utf8),
            deviceName: "First",
            platform: .macos,
            pairedAt: EngineFixtures.at(1)
        )
        let second = PairedPeer(
            certificateDER: Data("certificate-of-second".utf8),
            deviceName: "Second",
            platform: .linux,
            pairedAt: EngineFixtures.at(2)
        )
        try await store.savePairedPeer(second)
        try await store.savePairedPeer(first)

        #expect(try await store.pairedPeers().map(\.deviceName) == ["First", "Second"])
    }

    /// Design §11 puts the live-push toggle on the paired-device record rather
    /// than in preferences, and the reason is this test's last two assertions: a
    /// preference keyed by device identifier would outlive the pairing, and
    /// would silently re-apply if the same machine ever paired again.
    @Test("A live-push choice is stored against the peer", arguments: HistoryStoreEngine.all)
    func livePushChoiceIsStoredAgainstThePeer(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let peer = EngineFixtures.peer(named: "Peer")
        try await store.savePairedPeer(peer)

        // Nothing recorded, so design §3's platform default decides.
        #expect(try await store.livePushChoice(for: peer.deviceID) == .followsPlatformDefault)

        try await store.setLivePushChoice(.on, for: peer.deviceID)
        #expect(try await store.livePushChoice(for: peer.deviceID) == .on)
        try await store.setLivePushChoice(.off, for: peer.deviceID)
        #expect(try await store.livePushChoice(for: peer.deviceID) == .off)

        // Clearing it goes back to the default rather than to "off".
        try await store.setLivePushChoice(.followsPlatformDefault, for: peer.deviceID)
        #expect(try await store.livePushChoice(for: peer.deviceID) == .followsPlatformDefault)

        // Re-pairing does not reset a choice the user made about this machine.
        try await store.setLivePushChoice(.off, for: peer.deviceID)
        try await store.savePairedPeer(peer.renamed("Peer, renamed"))
        #expect(try await store.livePushChoice(for: peer.deviceID) == .off)

        // Forgetting it does, because a forgotten device is a stranger again.
        try await store.forgetPairedPeer(peer.deviceID)
        #expect(try await store.livePushChoice(for: peer.deviceID) == .followsPlatformDefault)
    }

    /// A preference is not a pairing. Writing one for a device nobody has
    /// approved would create a record out of a setting.
    @Test("A choice for an unpaired device is not recorded", arguments: HistoryStoreEngine.all)
    func aChoiceForAStrangerIsNotRecorded(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let stranger = EngineFixtures.peer(named: "Stranger").deviceID

        try await store.setLivePushChoice(.on, for: stranger)
        #expect(try await store.livePushChoice(for: stranger) == .followsPlatformDefault)
        #expect(try await store.pairedPeers().isEmpty)
    }
}
