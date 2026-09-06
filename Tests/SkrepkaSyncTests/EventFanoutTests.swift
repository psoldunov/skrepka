import Foundation
import Testing

@testable import SkrepkaSync

/// What ``PeerDiscovery/startBrowsing()`` promises every caller.
///
/// Handing two callers the same `AsyncStream` looks identical to this and is
/// not: a stream has one buffer and delivers each element to exactly one
/// consumer, so a peer list and a pairing coordinator reading one stream would
/// split three Macs between them and each show a subset — non-deterministically,
/// so it also looks different on every launch.
@Suite("Event fan-out")
struct EventFanoutTests {
    static func collect(_ stream: AsyncStream<String>) async -> [String] {
        var received: [String] = []
        for await element in stream { received.append(element) }
        return received
    }

    @Test("Every subscriber sees every event, in the order it was delivered")
    func everySubscriberSeesEverything() async {
        var fanout = EventFanout<String>()
        let list = fanout.subscribe { _ in }
        let pairing = fanout.subscribe { _ in }
        let logger = fanout.subscribe { _ in }

        for peer in ["mini", "studio", "book"] { fanout.deliver(peer) }
        fanout.finish()

        #expect(await Self.collect(list.stream) == ["mini", "studio", "book"])
        #expect(await Self.collect(pairing.stream) == ["mini", "studio", "book"])
        #expect(await Self.collect(logger.stream) == ["mini", "studio", "book"])
    }

    /// A consumer that goes away must not hold the browse open for the ones
    /// that are still reading, and must not go on buffering events nobody will
    /// take.
    @Test("A removed subscriber stops receiving and the rest carry on")
    func removingOneSubscriber() async {
        let (tokens, report) = AsyncStream<EventFanout<String>.Token>.makeStream()
        var fanout = EventFanout<String>()
        let leaving = fanout.subscribe { report.yield($0) }
        let staying = fanout.subscribe { report.yield($0) }

        fanout.deliver("before")
        fanout.remove(leaving.token)
        fanout.deliver("after")
        fanout.finish()

        // Ending a subscriber's stream is what reports its token, whether the
        // end came from `remove` or from `finish`.
        var reported: Set<EventFanout<String>.Token> = []
        for await token in tokens {
            reported.insert(token)
            if reported.count == 2 { break }
        }
        #expect(reported == [leaving.token, staying.token])

        // Everything already buffered still arrives; nothing after the removal
        // does.
        #expect(await Self.collect(leaving.stream) == ["before"])
        #expect(await Self.collect(staying.stream) == ["before", "after"])
    }

    /// `stopBrowsing()` then `startBrowsing()` is a supported sequence, and it
    /// runs straight through this: the second browse's subscribers must not
    /// inherit the first's tokens or its finished streams.
    @Test("A fan-out that finished can be subscribed to again")
    func reusableAfterFinishing() async {
        var fanout = EventFanout<String>()
        let before = fanout.subscribe { _ in }
        fanout.finish()

        let after = fanout.subscribe { _ in }
        #expect(after.token != before.token)
        fanout.deliver("studio")
        fanout.finish()

        #expect(await Self.collect(before.stream).isEmpty)
        #expect(await Self.collect(after.stream) == ["studio"])
    }
}
