import Testing

@testable import SkrepkaDaemon

/// The gate that holds calls between claiming the bus name and exporting the
/// object that answers them.
///
/// **What is not tested here, and why.** The race itself — the bus delivering
/// the calls it queued for an activated name straight after `RequestName` —
/// needs a live session bus with activation, which the build container has
/// not. The gate is generic over the call so its whole contract can be
/// asserted with integers instead: nothing held is lost, nothing is reordered,
/// and nothing waits once the gate is open.
@Suite("Holding calls until the interface is exported")
struct CallGateTests {
    /// What a receiver was handed, in the order it was handed it.
    actor Delivered {
        private(set) var calls: [Int] = []

        func append(_ call: Int) {
            calls.append(call)
        }
    }

    @Test("calls that arrive before the gate opens are delivered once it does, in order")
    func heldCallsAreDeliveredInOrder() async {
        let gate = CallGate<Int>()
        let delivered = Delivered()
        for call in 1...3 { await gate.receive(call) }
        #expect(await delivered.calls.isEmpty)

        await gate.open { await delivered.append($0) }

        #expect(await delivered.calls == [1, 2, 3])
    }

    @Test("a call that arrives after the gate opens goes straight through")
    func laterCallsPassStraightThrough() async {
        let gate = CallGate<Int>()
        let delivered = Delivered()
        await gate.open { await delivered.append($0) }

        await gate.receive(7)

        #expect(await delivered.calls == [7])
    }

    @Test("a call that lands while held calls are being delivered queues behind them")
    func aCallDuringOpeningDoesNotOvertake() async {
        let gate = CallGate<Int>()
        let delivered = Delivered()
        await gate.receive(1)
        await gate.receive(2)

        // The receiver takes a new call while it is still delivering the first
        // held one — what the connection's read loop does when the bus hands
        // it another call mid-drain. It must come out after 2, not before it.
        await gate.open { call in
            if call == 1 { await gate.receive(3) }
            await delivered.append(call)
        }

        #expect(await delivered.calls == [1, 2, 3])
    }

    @Test("past its capacity the gate drops calls rather than holding without bound")
    func capacityBoundsWhatIsHeld() async {
        let gate = CallGate<Int>(capacity: 2)
        let delivered = Delivered()
        for call in 1...4 { await gate.receive(call) }

        await gate.open { await delivered.append($0) }

        #expect(await delivered.calls == [1, 2])
    }

    @Test("only the first open names the receiver")
    func aSecondOpenIsIgnored() async {
        let gate = CallGate<Int>()
        let first = Delivered()
        let second = Delivered()
        await gate.open { await first.append($0) }
        await gate.open { await second.append($0) }

        await gate.receive(5)

        #expect(await first.calls == [5])
        #expect(await second.calls.isEmpty)
    }
}
