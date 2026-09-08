import Foundation
// For `ActionDocument.ok` / `.detail`, under `MemberImportVisibility`.
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// The dialling side records the pairing itself, so "paired" must not be said
/// before the record exists.
///
/// `SyncResponder` saves the peer the moment its own human accepts, while this
/// side saves only once the short authentication string is confirmed here — so
/// a `savePairedPeer` that threw *after* the answer had already gone out left
/// the client having printed "paired" for a pairing this device does not hold
/// and the far side does. The same one-sided state
/// ``PairError/oneSidedWarning`` exists to report, reached from the other
/// direction.
///
/// A throwing save cannot be induced on a real SQLite store, so the peer half
/// of the trust store is injected — `Daemon(… peers:)`, which production never
/// passes.
///
/// The proposal fixtures are ``PairingRefusalTests``'s, which cover this seam
/// from the refusal side: one set of fakes for one behaviour.
@Suite("An outgoing pairing is recorded before it is reported")
struct OutgoingPairingSaveTests {
    static func daemon(peers: any PairedDeviceStoring) throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-outgoing-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(
            options: options,
            environment: [:],
            pairingAnswerTimeout: .seconds(60),
            peers: peers
        )
    }

    @Test("the record exists by the time the answer says it does")
    func acceptSavesBeforeItAnswers() async throws {
        let peers = RecordingPeerStore()
        let daemon = try Self.daemon(peers: peers)
        let proposal = PairingRefusalTests.proposal(seed: 7)

        async let waiting = daemon.confirmPairing(proposal, direction: PairingDirection.outgoing)
        try await PairingRefusalTests.waitForPending(daemon, count: 1)
        let answer = await daemon.answerPairing(deviceID: proposal.peer.deviceID, accept: true)

        #expect(answer.ok)
        #expect(await peers.pairedPeer(proposal.peer.deviceID) != nil)
        #expect(await waiting)
    }

    @Test("a save that fails is reported as a failure, with the one-sided warning")
    func aFailedSaveIsNotReportedAsPaired() async throws {
        let peers = RecordingPeerStore(failsOnSave: true)
        let daemon = try Self.daemon(peers: peers)
        let proposal = PairingRefusalTests.proposal(seed: 8)

        async let waiting = daemon.confirmPairing(proposal, direction: PairingDirection.outgoing)
        try await PairingRefusalTests.waitForPending(daemon, count: 1)
        let answer = await daemon.answerPairing(deviceID: proposal.peer.deviceID, accept: true)

        #expect(answer.ok == false)
        #expect(answer.detail.contains(PairError.oneSidedWarning))
        // And the pairing did not quietly half-happen: nothing was recorded,
        // and the wait ends the way an unaccepted pairing does.
        #expect(await peers.saved.isEmpty)
        #expect(await waiting == false)
    }
}

/// A ``SkrepkaSync/PairedDeviceStoring`` that remembers what it was given, and
/// can be told to refuse.
///
/// `InMemoryTrustStore` is the shape, minus the identity half this does not
/// need and plus the one thing a real store will not do on demand.
actor RecordingPeerStore: PairedDeviceStoring {
    /// What a store that cannot write says. The daemon reports the failure
    /// rather than the error, so the case carries nothing.
    enum Failure: Error { case cannotWrite }

    private let failsOnSave: Bool
    private(set) var saved: [SyncDeviceID: PairedPeer] = [:]

    init(failsOnSave: Bool = false) {
        self.failsOnSave = failsOnSave
    }

    func pairedPeers() -> [PairedPeer] {
        saved.values.sorted { $0.deviceID < $1.deviceID }
    }

    func pairedPeer(_ deviceID: SyncDeviceID) -> PairedPeer? {
        saved[deviceID]
    }

    func savePairedPeer(_ peer: PairedPeer) throws {
        guard !failsOnSave else { throw Failure.cannotWrite }
        saved[peer.deviceID] = peer
    }

    func forgetPairedPeer(_ deviceID: SyncDeviceID) {
        saved[deviceID] = nil
    }

    func highestProtocolVersion(for deviceID: SyncDeviceID) -> ProtocolVersion? { nil }

    func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) {}

    func livePushChoice(for deviceID: SyncDeviceID) -> LivePushChoice { .followsPlatformDefault }

    func setLivePushChoice(_ choice: LivePushChoice, for deviceID: SyncDeviceID) {}
}
