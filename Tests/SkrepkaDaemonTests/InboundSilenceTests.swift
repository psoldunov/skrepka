import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// A paired peer this device reaches, that never reaches it back — the one
/// symptom of a firewall here that this machine can see.
@Suite("Inbound silence")
struct InboundSilenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let peer = SyncDeviceID(certificateDER: Data("a paired Mac".utf8))

    private func progress(syncedSecondsAgo seconds: TimeInterval?) -> [SyncDeviceID: PeerProgress] {
        var entry = PeerProgress()
        entry.firstSyncedAt = seconds.map { now.addingTimeInterval(-$0) }
        return [peer: entry]
    }

    /// What a NixOS machine behind its default firewall looked like: synced
    /// with the Mac every thirty seconds, and never once dialled by it.
    @Test("A peer reached for minutes that never dialled in is silent")
    func flagsAPeerThatNeverDialledIn() {
        let silent = InboundSilence.silentPeers(
            progress: progress(syncedSecondsAgo: 240), sighted: [peer], dialledIn: [], now: now)
        #expect(silent == [peer])
    }

    @Test("A peer that dialled in once is not")
    func acceptsAPeerThatDialledIn() {
        let silent = InboundSilence.silentPeers(
            progress: progress(syncedSecondsAgo: 240), sighted: [peer], dialledIn: [peer], now: now)
        #expect(silent.isEmpty)
    }

    /// A peer whose link was failing is still inside its sixty-second retry
    /// delay when this device first reaches it.
    @Test("A peer gets the grace period to dial in")
    func waitsOutTheGrace() {
        let silent = InboundSilence.silentPeers(
            progress: progress(syncedSecondsAgo: InboundSilence.grace - 1),
            sighted: [peer],
            dialledIn: [],
            now: now
        )
        #expect(silent.isEmpty)
    }

    @Test("A peer off the network, or never reached, says nothing about this firewall")
    func needsAReachablePeer() {
        let offline = InboundSilence.silentPeers(
            progress: progress(syncedSecondsAgo: 240), sighted: [], dialledIn: [], now: now)
        #expect(offline.isEmpty)

        let neverReached = InboundSilence.silentPeers(
            progress: progress(syncedSecondsAgo: nil), sighted: [peer], dialledIn: [], now: now)
        #expect(neverReached.isEmpty)
    }
}
