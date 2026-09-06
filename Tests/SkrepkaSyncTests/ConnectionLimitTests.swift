import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import SkrepkaSync

/// The ceilings a connection puts on the peer at the other end of it.
///
/// All three are the same shape of bug: something a remote party controls that
/// grows, or that it may ask for, with nothing saying how much or how often.
/// None of them shows up in a happy-path test, because a well-behaved peer never
/// reaches any of them — which is exactly why they are worth a suite.
@Suite("Connection limits")
struct ConnectionLimitTests {
    // MARK: - The inbound queue

    @Test("A producer past the mailbox's ceiling is cut off rather than buffered")
    func stopsAFloodingProducer() async {
        // `autoRead` is on and nothing applies backpressure, so this ceiling is
        // the only thing between a peer that streams frames at a responder
        // parked on a pairing sheet and a process the kernel kills.
        let mailbox = Mailbox<Int>(capacity: 2)
        let overflows = NIOLockedValueBox(0)
        mailbox.onOverflow { overflows.withLockedValue { $0 += 1 } }

        mailbox.deliver(1)
        mailbox.deliver(2)
        #expect(!mailbox.hasOverflowed)

        mailbox.deliver(3)
        #expect(mailbox.hasOverflowed)
        #expect(overflows.withLockedValue { $0 } == 1)

        // What was queued before the ceiling is still handed over and the
        // element that hit it is gone: the flood is dropped, not the
        // conversation that preceded it.
        #expect(await mailbox.next() == 1)
        #expect(await mailbox.next() == 2)
        mailbox.finish()
        #expect(await mailbox.next() == nil)
    }

    @Test("Two consumers parked on one mailbox are both answered")
    func wakesEveryParkedConsumer() async throws {
        // An actor does not serialise its own suspensions: `receive()` parks
        // inside `next()` and reentrancy lets a second `receive()` park there
        // too. Keeping one waiter and overwriting it drops a
        // `CheckedContinuation` on the floor, which is a permanent hang.
        let mailbox = Mailbox<Int>()
        async let first = mailbox.next()
        async let second = mailbox.next()

        // Long enough for both child tasks to have reached the suspension, so
        // the case under test — two waiters at once — is the one that runs.
        try await Task.sleep(for: .milliseconds(50))
        mailbox.deliver(1)
        mailbox.deliver(2)

        let firstValue = await first
        let secondValue = await second
        #expect(Set([firstValue, secondValue].compactMap { $0 }) == [1, 2])
    }

    // MARK: - What a peer may ask for the bytes of

    @Test("A payload request for a hash this connection was never offered is refused")
    func refusesAPayloadThatWasNeverOffered() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide)

        // The store holds these bytes — that is the point. Serving them to a
        // peer that was never offered the hash makes the responder an oracle: a
        // peer walks hashes and reads this device's contents out of which ones
        // come back non-empty.
        await #expect(
            throws: SyncTransportError.payloadNotOffered(contentHash: LoopbackHarness.contentHash)
        ) {
            _ = try await responder.replies(
                to: .payloadRequest(
                    contentHash: LoopbackHarness.contentHash,
                    key: LoopbackHarness.representation,
                    offset: 0
                )
            )
        }
        await pair.close()
    }

    @Test("A payload request for a hash this connection was offered is served")
    func servesAPayloadItOffered() async throws {
        // Without this the test above would still pass against a responder that
        // refused every payload request, which is a working rule and a broken
        // product.
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(
            serverPolicy: .pinned([harness.clientIdentity.deviceID]),
            clientPolicy: .pinned([harness.serverIdentity.deviceID])
        )
        let responder = harness.responder(for: pair.serverSide)

        _ = try await responder.replies(to: .indexRequest(since: nil))
        let replies = try await responder.replies(
            to: .payloadRequest(
                contentHash: LoopbackHarness.contentHash,
                key: LoopbackHarness.representation,
                offset: 0
            )
        )

        #expect(
            replies == [
                .payloadChunk(
                    PayloadChunk(
                        contentHash: LoopbackHarness.contentHash,
                        key: LoopbackHarness.representation,
                        offset: 0,
                        bytes: LoopbackHarness.payload,
                        isFinal: true
                    )
                )
            ]
        )
        await pair.close()
    }

    // MARK: - How many times a peer may ask to pair

    @Test("A second pairRequest on one connection is refused")
    func refusesASecondPairRequest() async throws {
        let harness = try await LoopbackHarness()
        defer { harness.shutdown() }
        let pair = try await harness.connectedPair(policy: .pairing)
        let responder = harness.responder(for: pair.serverSide)

        // Each accepted request raises a sheet in front of the user, and a
        // comparison of two short authentication strings is worth what the
        // user's attention on the tenth prompt is worth. First contact is one
        // request and one confirm; a second is a peer driving the prompt.
        let request = PairingSession(
            localIdentity: PeerIdentity(
                deviceID: harness.clientIdentity.deviceID,
                deviceName: "client",
                platform: .linux,
                protocolVersion: .current
            ),
            localCertificate: harness.clientIdentity
        ).pairRequest(at: harness.now)

        let answers = try await responder.replies(to: request)
        #expect(answers.map(\.type) == [.pairConfirm])

        await #expect(throws: SyncTransportError.repeatedPairRequest) {
            _ = try await responder.replies(to: request)
        }
        await pair.close()
    }
}
