import Foundation
import Testing

@testable import SkrepkaSync

/// Design §9's anti-downgrade rules, and the checks a `pairRequest` gets before
/// a human is shown anything.
@Suite("Pairing session")
struct PairingSessionTests {
    private static let local = try? DeviceCertificate.generate()
    private static let remote = try? DeviceCertificate.generate()

    private func session() throws -> PairingSession {
        let certificate = try #require(Self.local)
        return PairingSession(
            localIdentity: PeerIdentity(
                deviceID: certificate.deviceID,
                deviceName: "local",
                platform: .macos,
                protocolVersion: .current
            ),
            localCertificate: certificate
        )
    }

    private func identity(
        _ deviceID: SyncDeviceID,
        _ version: ProtocolVersion = .current,
        name: String = "peer"
    ) -> PeerIdentity {
        PeerIdentity(deviceID: deviceID, deviceName: name, platform: .linux, protocolVersion: version)
    }

    // MARK: - In-tunnel identity

    @Test("An identity that changed inside the tunnel is refused")
    func rejectsMismatchedInTunnelIdentity() throws {
        let before = identity(try #require(Self.local).deviceID)
        let after = identity(try #require(Self.remote).deviceID)

        #expect(
            throws: PairingError.identityChangedInsideTunnel(
                before: before.deviceID,
                after: after.deviceID
            )
        ) {
            try PairingSession.verifyInTunnelIdentity(before: before, after: after)
        }
    }

    @Test("A protocol version that changed inside the tunnel is refused")
    func rejectsMismatchedInTunnelProtocolVersion() throws {
        let deviceID = try #require(Self.remote).deviceID
        let before = identity(deviceID, ProtocolVersion(rawValue: 2))
        let after = identity(deviceID, .v1)

        #expect(
            throws: PairingError.protocolVersionChangedInsideTunnel(before: .init(rawValue: 2), after: .v1)
        ) {
            try PairingSession.verifyInTunnelIdentity(before: before, after: after)
        }
    }

    @Test("A display name that changed inside the tunnel is not an attack")
    func toleratesRenaming() throws {
        let deviceID = try #require(Self.remote).deviceID
        try PairingSession.verifyInTunnelIdentity(
            before: identity(deviceID, name: "old-laptop"),
            after: identity(deviceID, name: "new-laptop")
        )
    }

    // MARK: - The high-water mark

    @Test("A peer offering less than the highest version it has spoken is refused")
    func refusesProtocolDowngrade() {
        #expect(
            throws: PairingError.protocolDowngrade(offered: .v1, remembered: .init(rawValue: 3))
        ) {
            try PairingSession.verifyNoDowngrade(offered: .v1, remembered: ProtocolVersion(rawValue: 3))
        }
    }

    @Test("The same version, a higher one, and first contact all pass")
    func acceptsSameOrHigherOrUnknown() throws {
        try PairingSession.verifyNoDowngrade(offered: .v1, remembered: .v1)
        try PairingSession.verifyNoDowngrade(offered: ProtocolVersion(rawValue: 4), remembered: .v1)
        try PairingSession.verifyNoDowngrade(offered: .v1, remembered: nil)
    }

    @Test("The store's mark only ever rises")
    func highWaterMarkNeverFalls() async throws {
        let store = InMemoryTrustStore()
        let deviceID = try #require(Self.remote).deviceID
        await store.recordProtocolVersion(ProtocolVersion(rawValue: 3), for: deviceID)
        await store.recordProtocolVersion(.v1, for: deviceID)
        #expect(await store.highestProtocolVersion(for: deviceID) == ProtocolVersion(rawValue: 3))
    }

    // MARK: - The pair request

    @Test("A well-formed request produces a proposal and a string")
    func acceptsAWellFormedRequest() throws {
        let remote = try #require(Self.remote)
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
        let proposal = try session().proposal(
            for: request,
            presentedCertificateDER: remote.certificateDER,
            now: now
        )
        #expect(proposal.peer.deviceID == remote.deviceID)
        #expect(proposal.peer.platform == .linux)
        #expect(proposal.shortAuthenticationString.count == 9)
    }

    @Test("A request whose certificate does not hash to the claimed identity is refused")
    func rejectsACertificateThatDoesNotMatchTheClaim() throws {
        let remote = try #require(Self.remote)
        let claimed = try #require(Self.local).deviceID
        let now = Date()
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: claimed,
                deviceName: "peer",
                platform: .linux,
                certificateDER: remote.certificateDER,
                pairedAt: now
            )
        )
        #expect(
            throws: PairingError.certificateDoesNotMatchClaim(claimed: claimed, derived: remote.deviceID)
        ) {
            // Presented and carried agree, so the tunnel binding passes and the
            // claim is what this test is left pinning.
            _ = try session().proposal(
                for: request,
                presentedCertificateDER: remote.certificateDER,
                now: now
            )
        }
    }

    @Test("A request older than the freshness window is refused")
    func rejectsAStaleRequest() throws {
        let remote = try #require(Self.remote)
        let now = Date()
        let pairedAt = now.addingTimeInterval(-SyncLimits.pairingFreshnessWindow - 1)
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: remote.deviceID,
                deviceName: "peer",
                platform: .linux,
                certificateDER: remote.certificateDER,
                pairedAt: pairedAt
            )
        )
        // Named rather than `(any Error).self`: four guards run before this one,
        // so "it threw something" would still pass with the freshness check
        // deleted, which is the one thing this test exists to notice.
        #expect(throws: PairingError.stalePairingTimestamp(pairedAt: pairedAt, now: now)) {
            _ = try session().proposal(
                for: request,
                presentedCertificateDER: remote.certificateDER,
                now: now
            )
        }
    }

    @Test("A device is refused a pairing with itself")
    func rejectsSelfPairing() throws {
        let local = try #require(Self.local)
        let now = Date()
        let request = SyncMessage.pairRequest(
            PairRequest(
                deviceID: local.deviceID,
                deviceName: "me",
                platform: .macos,
                certificateDER: local.certificateDER,
                pairedAt: now
            )
        )
        #expect(throws: PairingError.selfPairing(deviceID: local.deviceID)) {
            _ = try session().proposal(
                for: request,
                presentedCertificateDER: local.certificateDER,
                now: now
            )
        }
    }

    @Test("Anything that is not a pairRequest is refused")
    func rejectsTheWrongMessage() throws {
        let remote = try #require(Self.remote)
        #expect(
            throws: SyncProtocolError.unexpectedMessage(expected: .pairRequest, got: .ping)
        ) {
            _ = try session().proposal(
                for: .ping(nonce: 1),
                presentedCertificateDER: remote.certificateDER,
                now: Date()
            )
        }
    }
}
