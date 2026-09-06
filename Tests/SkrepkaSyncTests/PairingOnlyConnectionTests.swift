import Foundation
import Testing

@testable import SkrepkaSync

/// What a connection made under ``PinPolicy/pairing`` will and will not carry.
///
/// The rule these prove is a security property rather than tidiness: a pairing
/// connection's peer presented a certificate no human has confirmed yet — that
/// confirmation is the entire point of ``ShortAuthString`` — so anything served
/// over it is served to whoever answered the advertisement. The rule lived in a
/// doc comment before it lived here, which is the shape an unenforced security
/// rule takes right up until it ships.
@Suite("Pairing-only connections")
struct PairingOnlyConnectionTests {
    // MARK: - The rule itself

    @Test("A pairing policy permits the two handshake messages and nothing else")
    func pairingPermitsOnlyTheHandshake() {
        let permitted = SyncMessageType.allCases.filter { PinPolicy.pairing.permits($0) }
        #expect(permitted == [.pairRequest, .pairConfirm])
    }

    @Test("A pinned policy permits every message the protocol has")
    func pinnedPermitsEverything() {
        // Exhaustive over `allCases` in both directions, so a message type added
        // in a later phase has to be classified rather than silently inheriting
        // whichever answer the switch happened to give it.
        #expect(SyncMessageType.allCases.allSatisfy { PinPolicy.pinned([]).permits($0) })
    }

    // MARK: - What the peer cannot ask for

    @Test("A pairing connection asked for an index refuses and names the message")
    func refusesAnIndexRequestWhilePairing() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        // Framed by the encoder and written past `send(_:)`, because `send(_:)`
        // enforces the same rule: the peer being modelled here is one that does
        // not.
        try await pair.client.sendUnframed(Array(FrameCodec.encode(.indexRequest(since: nil))))

        await #expect(throws: SyncPolicyError.peerSentOutsidePairing(.indexRequest)) {
            _ = try await pair.serverSide.receive()
        }
        #expect(await pair.serverSide.diagnosticsSnapshot().refusedOutsidePairing == [.indexRequest])
        await pair.close()
    }

    @Test("A pairing connection asked for a payload is refused")
    func refusesAPayloadRequestWhilePairing() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        let request = SyncMessage.payloadRequest(
            contentHash: LoopbackHarness.contentHash,
            key: LoopbackHarness.representation,
            offset: 0
        )
        try await pair.client.sendUnframed(Array(FrameCodec.encode(request)))

        await #expect(throws: SyncPolicyError.peerSentOutsidePairing(.payloadRequest)) {
            _ = try await pair.serverSide.receive()
        }
        #expect(await pair.serverSide.diagnosticsSnapshot().refusedOutsidePairing == [.payloadRequest])
        await pair.close()
    }

    @Test("A refused message costs the connection, not just the frame")
    func aRefusalDropsTheWholeConnection() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)

        // A forbidden frame and, right behind it in the same write, one the
        // policy does carry. Dropping only the frame would hand the second one
        // out on the next read; dropping the connection cannot.
        let permitted = SyncMessage.pairConfirm(
            deviceID: harness.clientIdentity.deviceID,
            accepted: true,
            shortAuthenticationString: "A3F2-91BC"
        )
        try await pair.client.sendUnframed(
            Array(FrameCodec.encode(.indexRequest(since: nil))) + Array(FrameCodec.encode(permitted))
        )

        await #expect(throws: SyncPolicyError.peerSentOutsidePairing(.indexRequest)) {
            _ = try await pair.serverSide.receive()
        }
        await #expect(throws: SyncPolicyError.peerSentOutsidePairing(.indexRequest)) {
            _ = try await pair.serverSide.receive()
        }
        await pair.close()
    }

    // MARK: - What this device will not ask for

    @Test("The initiator refuses to request an index on a pairing connection")
    func initiatorWillNotRequestAnIndexWhilePairing() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)
        let initiator = try harness.initiator(for: pair.client)

        await #expect(throws: SyncPolicyError.refusedToSendOutsidePairing(.indexRequest)) {
            _ = try await initiator.requestIndex(since: nil)
        }
        // Nothing reached the wire, so the peer saw no reason to hang up and the
        // pairing a user may be halfway through survives this side's bug.
        #expect(await pair.serverSide.diagnosticsSnapshot().refusedOutsidePairing.isEmpty)
        await pair.close()
    }

    @Test("The initiator refuses to fetch a payload on a pairing connection")
    func initiatorWillNotFetchAPayloadWhilePairing() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)
        let initiator = try harness.initiator(for: pair.client)

        await #expect(throws: SyncPolicyError.refusedToSendOutsidePairing(.payloadRequest)) {
            _ = try await initiator.fetchPayload(
                contentHash: LoopbackHarness.contentHash,
                key: LoopbackHarness.representation
            )
        }
        await pair.close()
    }

    @Test("The initiator refuses to say hello on a pairing connection")
    func initiatorWillNotHandshakeWhilePairing() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)
        let initiator = try harness.initiator(for: pair.client)

        // `hello` looks harmless and is not: answering one writes a protocol
        // version into the responder's trust store, which is persistent state
        // about a device nobody has approved.
        await #expect(throws: SyncPolicyError.refusedToSendOutsidePairing(.hello)) {
            _ = try await initiator.handshake()
        }
        await pair.close()
    }

    // MARK: - The other arm

    @Test("A pinned connection carries what a pairing one refuses")
    func pinnedConnectionsCarryEverything() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )

        // Without this the suite above would still pass against a transport that
        // refused an index request on every connection, which would be a working
        // rule and a broken product.
        try await pair.client.send(.indexRequest(since: nil))
        #expect(try await pair.serverSide.receive() == .indexRequest(since: nil))
        #expect(await pair.serverSide.diagnosticsSnapshot().refusedOutsidePairing.isEmpty)
        await pair.close()
    }
}
