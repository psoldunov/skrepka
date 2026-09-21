import Foundation
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// Work that began under one sync stack and resumes after it stopped.
///
/// `SetSettings(syncEnabled: false)` tears the network half down while a dial,
/// a proposal or a push may be suspended inside it. These pin that each one is
/// dropped on resuming rather than acting on a stack that no longer exists.
@Suite("Work from a stopped sync stack is dropped")
struct SyncGenerationTests {
    static func meta() throws -> SyncClipMeta {
        let device = try #require(SyncDeviceID(hex: String(repeating: "c", count: SyncDeviceID.hexLength)))
        let stamp = Date()
        return SyncClipMeta(
            contentHash: String(repeating: "d", count: 64),
            kind: ClipKind.text.rawValue,
            preview: "pushed",
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: []
        )
    }

    static let inline = [
        RepresentationKey(canonical: "text/plain", origin: "public.utf8-plain-text"): Data("pushed".utf8)
    ]

    @Test("a pairing whose dial lands after sync went off files nothing and throws")
    func lateDialFilesNothing() async throws {
        let daemon = try PairingRefusalTests.daemon(answering: .seconds(60))
        let generation = await daemon.syncGeneration
        // What `SetSettings(syncEnabled: false)` does while the dial is out.
        await daemon.stopSyncStack(closingSystemBus: false)

        await #expect(throws: PairingWindowError.self) {
            try await daemon.fileOutgoing(PairingRefusalTests.proposal(seed: 41), generation: generation)
        }
        #expect(await daemon.pendingProposals().isEmpty)
    }

    @Test("a pairing whose dial lands on the same stack is filed")
    func currentDialIsFiled() async throws {
        let daemon = try PairingRefusalTests.daemon(answering: .seconds(60))
        let generation = await daemon.syncGeneration
        let proposal = PairingRefusalTests.proposal(seed: 42)
        let document = try await daemon.fileOutgoing(proposal, generation: generation)
        #expect(document.direction == PairingDirection.outgoing)
        #expect(await daemon.pendingProposals().count == 1)
        await daemon.stop()
    }

    @Test("an inbound proposal from a stopped stack is refused unasked")
    func staleInboundProposalIsRefused() async throws {
        let daemon = try PairingRefusalTests.daemon(answering: .seconds(60))
        let generation = await daemon.syncGeneration
        await daemon.stopSyncStack(closingSystemBus: false)

        let accepted = await daemon.confirmPairing(
            PairingRefusalTests.proposal(seed: 43),
            direction: PairingDirection.incoming,
            generation: generation)
        #expect(accepted == false)
        #expect(await daemon.pendingProposals().isEmpty)
    }

    @Test("a live push arriving after sync went off writes nothing")
    func lateLivePushWritesNothing() async throws {
        let daemon = try PairingRefusalTests.daemon(answering: .seconds(60))
        let generation = await daemon.syncGeneration
        #expect(await daemon.receiveLivePush(try Self.meta(), inline: Self.inline, generation: generation))

        await daemon.stopSyncStack(closingSystemBus: false)
        let meta = try Self.meta()
        let afterOff = await daemon.receiveLivePush(meta, inline: Self.inline, generation: generation)
        #expect(afterOff == false)

        // Off and on again is still not the stack the push came in on.
        await daemon.advanceSyncGeneration()
        let afterOn = await daemon.receiveLivePush(meta, inline: Self.inline, generation: generation)
        #expect(afterOn == false)
    }

    @Test("a link report from a stopped stack records no progress")
    func staleLinkReportIsDropped() async throws {
        let daemon = try PairingRefusalTests.daemon(answering: .seconds(60))
        let device = PairingRefusalTests.proposal(seed: 44).peer.deviceID
        let generation = await daemon.syncGeneration
        await daemon.stopSyncStack(closingSystemBus: false)

        await daemon.apply(.connecting, to: device, generation: generation)
        #expect(await daemon.progress[device] == nil)
    }
}

extension Daemon {
    /// The pre-generation spellings the older tests use: work on the stack
    /// that is live now.
    func confirmPairing(_ proposal: PairingProposal, direction: String) async -> Bool {
        await confirmPairing(proposal, direction: direction, generation: syncGeneration)
    }

    func apply(_ event: PeerLinkEvent, to deviceID: SyncDeviceID) {
        apply(event, to: deviceID, generation: syncGeneration)
    }
}
