import Foundation
import Testing

@testable import SkrepkaSync

/// That a pairing is built from the certificate the peer completed the
/// handshake with, and never from the one it typed into the message.
///
/// The distinction is the whole of the responder's man-in-the-middle defence and
/// it is invisible in a happy-path test, because a well-behaved peer sends the
/// certificate it is holding. Under ``PinPolicy/pairing`` the verification
/// callback accepts any well-formed leaf — it has to, since nothing is pinned at
/// first contact — so an attacker opens the tunnel with a certificate of its own
/// and asks to pair one it harvested from another of the user's machines. A
/// responder that pairs from the request body shows the user a short
/// authentication string derived from a public key nobody on the connection
/// holds, and then pins a device that never authenticated here.
@Suite("Tunnel binding")
struct TunnelBindingTests {
    private static let local = try? DeviceCertificate.generate()
    private static let remote = try? DeviceCertificate.generate()

    private func session(_ certificate: DeviceCertificate) -> PairingSession {
        PairingSession(
            localIdentity: PeerIdentity(
                deviceID: certificate.deviceID,
                deviceName: "local",
                platform: .macos,
                protocolVersion: .current
            ),
            localCertificate: certificate
        )
    }

    @Test("A request carrying a certificate the peer did not present is refused")
    func rejectsACertificateTheTunnelDidNotPresent() throws {
        let claimed = try #require(Self.remote)
        let presented = try #require(Self.local)
        let now = Date()
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: claimed.deviceID,
                deviceName: "peer",
                platform: .linux,
                certificateDER: claimed.certificateDER,
                pairedAt: now
            )
        )

        // A third identity for the local side, so `selfPairing` cannot be what
        // fires here — the refusal has to come from the tunnel binding.
        let pairingSession = session(try DeviceCertificate.generate())
        #expect(
            throws: PairingError.certificateDoesNotMatchTunnel(
                claimed: claimed.deviceID,
                presented: presented.deviceID
            )
        ) {
            _ = try pairingSession.proposal(
                for: request,
                presentedCertificateDER: presented.certificateDER,
                now: now
            )
        }
    }

    @Test("The proposal is built from the certificate the peer presented")
    func buildsTheProposalFromTheTunnelCertificate() throws {
        let remote = try #require(Self.remote)
        let local = try #require(Self.local)
        let now = Date()
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: remote.deviceID,
                deviceName: "peer",
                platform: .linux,
                certificateDER: remote.certificateDER,
                pairedAt: now
            )
        )
        let proposal = try session(local).proposal(
            for: request,
            presentedCertificateDER: remote.certificateDER,
            now: now
        )

        // Both halves, because either one taken from the body alone is the bug:
        // the pin has to be the presented bytes, and the string has to be over
        // the presented key.
        #expect(proposal.peer.certificateDER == remote.certificateDER)
        #expect(
            proposal.shortAuthenticationString
                == ShortAuthString.derive(
                    publicKeys: [local.publicKeyBytes, remote.publicKeyBytes],
                    pairedAt: now
                )
        )
    }

    @Test("A pairRequest carrying a certificate the tunnel did not present is refused")
    func refusesAPairRequestForAnotherDevicesCertificate() async throws {
        // The same rule, reached the way an attacker would reach it: over a real
        // tunnel, through `SyncResponder`, on a connection whose peer is the
        // loopback client and whose request names somebody else.
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)
        let responder = harness.responder(for: pair.serverSide)

        let elsewhere = try DeviceCertificate.generate()
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: elsewhere.deviceID,
                deviceName: "the laptop in the next room",
                platform: .linux,
                certificateDER: elsewhere.certificateDER,
                pairedAt: harness.now
            )
        )

        await #expect(
            throws: PairingError.certificateDoesNotMatchTunnel(
                claimed: elsewhere.deviceID,
                presented: harness.clientIdentity.deviceID
            )
        ) {
            _ = try await responder.replies(to: request)
        }
        // Nothing was proposed, so nothing could have been shown or saved.
        #expect(await responder.lastProposal() == nil)
        await pair.close()
    }
}
