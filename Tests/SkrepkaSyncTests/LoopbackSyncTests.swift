import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import SkrepkaSync

/// The phase's proof: two connections in one process, over a real TLS 1.3
/// tunnel on the loopback interface.
///
/// `rejectsUnpinnedCertificate` was written before ``SyncTLS`` had a
/// verification callback at all, because a pinning callback that returns
/// "trusted" on the wrong branch produces code that works perfectly and
/// protects nothing — the only thing that tells the two apart is a test that
/// puts an unpinned certificate on the wire.
@Suite("Loopback sync")
struct LoopbackSyncTests {
    // MARK: - The security proof

    @Test("A peer with a valid but unpinned certificate is refused")
    func rejectsUnpinnedCertificate() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }

        // A third device, never paired with either end. Its certificate is
        // perfectly valid — self-signed, in date, correctly formed — and that
        // is the point: validity is not the question a pin asks.
        let stranger = try DeviceCertificate.generate()

        let server = try await harness.startServer(
            identity: stranger,
            policy: .pinned([harness.clientIdentity.deviceID])
        )

        await #expect(throws: SyncTLSError.unpinnedCertificate(stranger.deviceID)) {
            _ = try await SyncClient.connect(
                host: LoopbackHarness.host,
                port: server.port,
                identity: harness.clientIdentity,
                // The client pins the server it expects, and gets `stranger`.
                policy: .pinned([harness.serverIdentity.deviceID]),
                group: harness.group
            )
        }
        await server.stop()
    }

    @Test("A client the server has not pinned is refused by the server")
    func serverRefusesAnUnpinnedClient() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let stranger = try DeviceCertificate.generate()

        // Mutual authentication means both directions pin. The client-side
        // refusal above is the visible one because TLS 1.3 lets a client finish
        // before the server has looked at its certificate — so this asserts the
        // other direction, which would otherwise be untested and would fail
        // open.
        let server = try await harness.startServer(
            identity: harness.serverIdentity,
            policy: .pinned([stranger.deviceID])
        )
        _ = try? await SyncClient.connect(
            host: LoopbackHarness.host,
            port: server.port,
            identity: harness.clientIdentity,
            policy: .pinned([harness.serverIdentity.deviceID]),
            group: harness.group
        )

        let refusal = try await harness.eventually { server.refusals().first }
        #expect(refusal.contains(harness.clientIdentity.deviceID.hex))
        #expect(refusal.contains("not pinned"))
        await server.stop()
    }

    @Test("A frame type this build does not know costs the frame, not the connection")
    func skipsAnUnknownFrameType() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        // Pinned rather than `.pairing`: this is about what an ordinary
        // connection tolerates, and a pairing one carries nothing but the
        // handshake — see ``PairingOnlyConnectionTests``.
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        // `[u32 length][u8 type][CBOR body]`, with a type byte no build has
        // ever used and an empty CBOR map for a body.
        try await pair.client.sendUnframed([0, 0, 0, 2, 200, 0xA0])
        try await pair.client.send(.ping(nonce: 7))

        #expect(try await pair.serverSide.receive() == .ping(nonce: 7))
        #expect(await pair.serverSide.diagnosticsSnapshot().unknownFrameTypes == [200])
        await pair.close()
    }

    @Test("A configuration with verification disabled is refused at construction")
    func refusesConfigurationWithVerificationDisabled() throws {
        let identity = try DeviceCertificate.generate()
        let chain = try SyncTLS.certificateSource(identity)
        let key = try SyncTLS.privateKeySource(identity)

        // The factory that makes the trap easy to reach: it sets
        // `certificateVerification: .none` and `minimumTLSVersion: .tlsv1`.
        var trap = TLSConfiguration.makeServerConfiguration(certificateChain: [chain], privateKey: key)
        trap.minimumTLSVersion = .tlsv13

        #expect(throws: SyncTLSError.verificationDisabled) {
            _ = try SyncTLS.context(for: trap)
        }

        // And the same configuration with only the verification mode corrected
        // is accepted, so the test is pinning the one field rather than
        // "anything from that factory".
        var corrected = trap
        corrected.certificateVerification = .noHostnameVerification
        corrected.trustRoots = .certificates([])
        #expect(throws: Never.self) { _ = try SyncTLS.context(for: corrected) }
    }

    @Test("A frame declaring a 4 GB body is refused from its length prefix alone")
    func rejectsOversizedFrameBeforeAllocating() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        // Four bytes, and not one byte more: a length prefix declaring
        // 4,294,967,294 bytes of body. If the decoder waits for the body before
        // deciding, this process asks the allocator for 4 GB; the error below
        // can only have been raised from those four bytes, because no others
        // were ever sent.
        try await pair.client.sendUnframed([0xFF, 0xFF, 0xFF, 0xFF])

        await #expect(throws: FrameError.bodyTooLarge(declaredBytes: 4_294_967_294)) {
            _ = try await pair.serverSide.receive()
        }
        await pair.close()
    }

    // MARK: - The phase's proof

    @Test("Two connections in one process pair, exchange indexes and fetch a payload")
    func pairsIndexesAndFetches() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }

        // 1. First contact. Neither device has anything to pin, so the tunnel
        //    proves only that both ends share it and the short authentication
        //    string is the authentication.
        let firstContact = try await harness.connectedPair(policy: .pairing)
        let responder = harness.responder(for: firstContact.serverSide)
        let serving = Task { try await responder.serve() }

        // Nothing to expect at first contact: the whole point of `.pairing` is
        // that this device has never met the one answering.
        let initiator = try harness.initiator(for: firstContact.client, expecting: nil)
        let proposal = try await initiator.pair(at: harness.now)
        #expect(proposal.shortAuthenticationString.count == ShortAuthString.renderedLength)
        #expect(proposal.peer.deviceID == harness.serverIdentity.deviceID)

        // Both ends derived the same string without agreeing who went first.
        let serverProposal = try #require(await responder.lastProposal())
        #expect(serverProposal.shortAuthenticationString == proposal.shortAuthenticationString)

        await firstContact.close()
        serving.cancel()

        // 2. A second connection, now pinned to the certificate each end saw.
        await harness.serverTrust.savePairedPeer(serverProposal.peer)
        let pinned = try await harness.connectedPair(
            serverPolicy: .pinned(await harness.serverTrust.pinnedDeviceIDs()),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        #expect(pinned.client.peerDeviceID == harness.serverIdentity.deviceID)
        #expect(pinned.serverSide.peerDeviceID == harness.clientIdentity.deviceID)

        let pinnedResponder = harness.responder(for: pinned.serverSide)
        let pinnedServing = Task { try await pinnedResponder.serve() }
        let pinnedInitiator = try harness.initiator(
            for: pinned.client,
            expecting: harness.serverIdentity.deviceID
        )

        // 3. Hello, re-sent inside the tunnel, checked against the identity the
        //    certificate proved and against the remembered protocol version.
        let peer = try await pinnedInitiator.handshake()
        #expect(peer.deviceID == harness.serverIdentity.deviceID)
        #expect(peer.protocolVersion == .current)

        // 4. Index.
        let offer = try await pinnedInitiator.requestIndex(since: nil)
        #expect(offer.items.map(\.contentHash) == [LoopbackHarness.contentHash])
        #expect(offer.tombstones.isEmpty)

        // 5. Payload, fetched from the peer that offered the representation.
        let key = try #require(offer.items.first?.representations.first?.key)
        let bytes = try await pinnedInitiator.fetchPayload(
            contentHash: LoopbackHarness.contentHash,
            key: key
        )
        #expect(bytes == LoopbackHarness.payload)

        await pinned.close()
        pinnedServing.cancel()
    }
}
