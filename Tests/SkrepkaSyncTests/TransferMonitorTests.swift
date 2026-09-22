import Foundation
import Testing

@testable import SkrepkaSync

/// What a picker's progress bars are drawn from.
@Suite("The transfer monitor")
struct TransferMonitorTests {
    private static let total = TransferMonitor.reportingThreshold * 4

    @Test("A fetch of one chunk or less is never reported")
    func smallFetchesAreSilent() async {
        let monitor = TransferMonitor(progressInterval: .zero)
        await monitor.begin("a", totalBytes: TransferMonitor.reportingThreshold)
        await monitor.advance("a", to: 10)
        #expect(await monitor.current.isEmpty)
    }

    @Test("Beginning, advancing and ending are each seen, in order")
    func lifecycle() async {
        let monitor = TransferMonitor(progressInterval: .zero)
        var updates = await monitor.updates().makeAsyncIterator()
        #expect(await updates.next()?.isEmpty == true)

        await monitor.begin("a", totalBytes: Self.total)
        #expect(
            await updates.next() == [
                PayloadTransfer(contentHash: "a", receivedBytes: 0, totalBytes: Self.total)
            ])

        await monitor.advance("a", to: Self.total / 2)
        let halfway = await updates.next()
        #expect(halfway?.first?.fraction == 0.5)

        await monitor.end("a")
        #expect(await updates.next()?.isEmpty == true)
    }

    @Test("A new subscriber starts from the transfers in flight")
    func subscribersStartFromNow() async {
        let monitor = TransferMonitor(progressInterval: .zero)
        await monitor.begin("b", totalBytes: Self.total)
        await monitor.begin("a", totalBytes: Self.total)
        var updates = await monitor.updates().makeAsyncIterator()
        #expect(await updates.next()?.map(\.contentHash) == ["a", "b"])
    }

    @Test("Two fetches of one item keep its bar until both have ended")
    func overlappingFetches() async {
        let monitor = TransferMonitor(progressInterval: .zero)
        await monitor.begin("a", totalBytes: Self.total)
        await monitor.begin("a", totalBytes: Self.total)
        await monitor.end("a")
        #expect(await monitor.current.map(\.contentHash) == ["a"])
        await monitor.end("a")
        #expect(await monitor.current.isEmpty)
        // An end with nothing begun, as a fetch under the threshold makes, is ignored.
        await monitor.end("a")
        #expect(await monitor.current.isEmpty)
    }

    @Test("A small fetch of an item ending does not take a large fetch's bar with it")
    func smallFetchDoesNotEndALargeOne() async {
        let monitor = TransferMonitor(progressInterval: .zero)
        await monitor.begin("a", totalBytes: Self.total)
        await monitor.begin("a", totalBytes: 10)
        await monitor.end("a")
        #expect(await monitor.current.map(\.contentHash) == ["a"])
        await monitor.end("a")
        #expect(await monitor.current.isEmpty)
    }

    @Test("Progress is spaced out; nothing reported yet is always due")
    func spacing() {
        let start = ContinuousClock.now
        let interval = Duration.milliseconds(100)
        #expect(TransferMonitor.isDue(start, lastReport: nil, interval: interval))
        #expect(!TransferMonitor.isDue(start + .milliseconds(40), lastReport: start, interval: interval))
        #expect(TransferMonitor.isDue(start + .milliseconds(100), lastReport: start, interval: interval))
    }

    @Test("A fraction never runs past full, whatever the peer claimed")
    func fractionIsClamped() {
        #expect(PayloadTransfer(contentHash: "a", receivedBytes: 300, totalBytes: 200).fraction == 1)
        #expect(PayloadTransfer(contentHash: "a", receivedBytes: 5, totalBytes: 0).fraction == 0)
    }

    @Test("The plan counts what fits the budget, in order")
    func plannedBytes() {
        let descriptors = [100, 50, 400, 25].map {
            RepresentationDescriptor(key: FileSyncFixtures.fileURLKey, byteCount: $0)
        }
        #expect(SyncExchange.plannedBytes(descriptors, budget: 200) == 175)
        #expect(SyncExchange.plannedBytes(descriptors, budget: 0) == 0)
    }
}
