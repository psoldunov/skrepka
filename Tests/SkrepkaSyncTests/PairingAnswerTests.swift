import Foundation
import Testing

@testable import SkrepkaSync

/// The checks ``SyncInitiator`` runs on the answer a peer gives it.
///
/// Every one of them is a `guard` over a value the peer chose, which is the
/// class of code that works perfectly and protects nothing: invert
/// `expected == remoteString` in ``SyncInitiator/pair(at:)`` and a pairing still
/// completes, a string still appears on screen, and no test that only exercises
/// the happy path notices. So each guard gets a peer that lies in exactly one
/// way and nothing else.
///
/// The lying peer is built out of ``SyncConnection/sendUnframed(_:)`` on the far
/// end of a real loopback tunnel, so what is under test is the initiator's own
/// logic rather than a mock's. The mirror-image rule on the responder — that a
/// pairing is bound to the certificate the tunnel presented — is in
/// ``TunnelBindingTests``.
@Suite("Pairing answers")
struct PairingAnswerTests {
    @Test("A pairConfirm carrying a different short authentication string is refused")
    func refusesAMismatchedShortAuthenticationString() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        let expected = ShortAuthString.derive(
            publicKeys: [
                harness.clientIdentity.publicKeyBytes,
                harness.serverIdentity.publicKeyBytes,
            ],
            pairedAt: harness.now
        )
        let lie = "0000-0000"
        try await pair.serverSide.sendUnframed(
            Array(
                FrameCodec.encode(
                    .pairConfirm(
                        deviceID: harness.serverIdentity.deviceID,
                        accepted: true,
                        shortAuthenticationString: lie
                    )
                )
            )
        )

        let initiator = try harness.initiator(for: pair.client, expecting: nil)
        let pairedAt = harness.now
        await #expect(
            throws: PairingError.shortAuthenticationStringMismatch(local: expected, remote: lie)
        ) {
            _ = try await initiator.pair(at: pairedAt)
        }
        await pair.close()
    }

    @Test("A pairConfirm naming a device other than the tunnel's is refused")
    func refusesAConfirmFromAnotherDevice() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        // A relay's shape: the confirm is well formed and the string in it is
        // even correct, but it claims to come from a device that is not the one
        // holding the other end of this tunnel.
        let expected = ShortAuthString.derive(
            publicKeys: [
                harness.clientIdentity.publicKeyBytes,
                harness.serverIdentity.publicKeyBytes,
            ],
            pairedAt: harness.now
        )
        try await pair.serverSide.sendUnframed(
            Array(
                FrameCodec.encode(
                    .pairConfirm(
                        deviceID: harness.clientIdentity.deviceID,
                        accepted: true,
                        shortAuthenticationString: expected
                    )
                )
            )
        )

        let initiator = try harness.initiator(for: pair.client, expecting: nil)
        let pairedAt = harness.now
        await #expect(
            throws: PairingError.identityChangedInsideTunnel(
                before: harness.serverIdentity.deviceID,
                after: harness.clientIdentity.deviceID
            )
        ) {
            _ = try await initiator.pair(at: pairedAt)
        }
        await pair.close()
    }

    @Test("A peer that declines is reported as declining rather than as a fault")
    func reportsARefusalByThePeer() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        try await pair.serverSide.sendUnframed(
            Array(
                FrameCodec.encode(
                    .pairConfirm(
                        deviceID: harness.serverIdentity.deviceID,
                        accepted: false,
                        shortAuthenticationString: "0000-0000"
                    )
                )
            )
        )

        let initiator = try harness.initiator(for: pair.client, expecting: nil)
        let pairedAt = harness.now
        await #expect(throws: PairingError.rejectedByPeer) {
            _ = try await initiator.pair(at: pairedAt)
        }
        await pair.close()
    }

    @Test("An initiator pointed at one device refuses a tunnel to another")
    func refusesATunnelToTheWrongPairedPeer() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        // What a spoofed Bonjour answer buys an attacker: the tunnel lands on a
        // device that is genuinely paired, just not the one that was dialled.
        // Every layer below notices nothing, because `.pinned` carries the whole
        // paired set and this peer is in it.
        let elsewhere = try DeviceCertificate.generate()
        #expect(
            throws: PairingError.reachedTheWrongPeer(
                expected: elsewhere.deviceID,
                reached: harness.serverIdentity.deviceID
            )
        ) {
            _ = try harness.initiator(for: pair.client, expecting: elsewhere.deviceID)
        }
        await pair.close()
    }
}
