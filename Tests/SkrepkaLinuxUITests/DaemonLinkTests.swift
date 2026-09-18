import Foundation
import SkrepkaIPC
import Testing

@testable import SkrepkaLinuxUI

/// The order the Settings window talks to the daemon in.
///
/// The daemon answers one call at a time, so a poll sent behind a thirty-second
/// dial would time out — and a timeout drops the bus session under the dial.
/// These hold an action in flight on a fake daemon and check what else is sent
/// meanwhile.
@Suite("Settings: the daemon link")
struct DaemonLinkTests {
    typealias Fixture = SyncFixtures

    /// A started link with no poll, so every call the fake sees is one a test
    /// asked for.
    static func link(_ daemon: FakeSyncDaemon, _ log: EventLog) async -> DaemonLink {
        let link = DaemonLink(connect: { daemon }, report: { log.append($0) })
        await link.start(pollingEvery: nil, retryingAfter: .milliseconds(10))
        return link
    }

    /// Waits until the fake has seen `call` start, or five seconds pass.
    static func waitForCall(_ call: String, on daemon: FakeSyncDaemon) async -> Bool {
        for _ in 0..<500 {
            if await daemon.calls.contains(call) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("a poll is dropped while an action is in flight, and the action refreshes the list itself")
    func pollWaitsForNothing() async {
        let daemon = FakeSyncDaemon(document: Fixture.document([Fixture.paired()]))
        let log = EventLog()
        let link = await Self.link(daemon, log)
        await daemon.hold("unpair")

        link.perform(.unpair(deviceID: Fixture.macID))
        let started = await Self.waitForCall("start unpair", on: daemon)
        link.refreshIfIdle()
        try? await Task.sleep(for: .milliseconds(50))
        let during = await daemon.calls
        #expect(started)
        #expect(during == ["start unpair"])

        await daemon.release("unpair")
        let events = await log.waitFor(1)
        let after = await daemon.calls
        #expect(after == ["start unpair", "end unpair", "start peers", "end peers"])
        guard case .finished(.unpair(Fixture.macID), .answered(let answer), let refreshed)? = events.first
        else {
            Issue.record("expected the unpair to finish, got \(events)")
            return
        }
        #expect(answer.ok)
        #expect(refreshed != nil)
    }

    @Test("actions run one at a time, in the order they were sent")
    func actionsAreSerial() async {
        let daemon = FakeSyncDaemon(document: Fixture.document([Fixture.paired()]))
        let log = EventLog()
        let link = await Self.link(daemon, log)
        await daemon.hold("syncNow")

        link.perform(.syncNow)
        link.perform(.setLivePush(deviceID: Fixture.macID, isOn: false))
        let started = await Self.waitForCall("start syncNow", on: daemon)
        try? await Task.sleep(for: .milliseconds(50))
        let during = await daemon.calls
        #expect(started)
        #expect(during == ["start syncNow"])

        await daemon.release("syncNow")
        _ = await log.waitFor(2)
        let expected = [
            "start syncNow", "end syncNow", "start peers", "end peers",
            "start setLivePush off", "end setLivePush off", "start peers", "end peers",
        ]
        let calls = await daemon.calls
        #expect(calls == expected)
    }

    @Test("an unreachable daemon ends every action with a failure rather than dropping it")
    func unreachableDaemon() async {
        let log = EventLog()
        let notRunning = IPCError.busError(
            member: "Peers", name: "org.freedesktop.DBus.Error.ServiceUnknown", detail: "")
        let link = DaemonLink(connect: { throw notRunning }, report: { log.append($0) })
        await link.start(pollingEvery: nil, retryingAfter: .milliseconds(10))

        link.perform(.syncNow)
        _ = await log.waitFor(1)
        link.refreshIfIdle()
        let events = await log.waitFor(2)
        let failure = SyncFailure(describing: notRunning)
        #expect(events.first == .finished(.syncNow, .failed(failure), refreshed: nil))
        #expect(events.dropFirst().first == .unreachable(failure))
    }

    @Test("closing the window closes a pairing window it opened")
    func shutdownClosesItsOwnWindow() async {
        let daemon = FakeSyncDaemon(document: Fixture.document())
        let log = EventLog()
        let link = await Self.link(daemon, log)

        await daemon.setDocument(Fixture.document(pairingPort: 5555))
        link.perform(.openPairingWindow)
        _ = await log.waitFor(1)
        await link.shutdown()

        let calls = await daemon.calls
        #expect(calls.contains("start closePairing"))
        #expect(log.all.last == .shutDown)
    }

    @Test("…and leaves alone one that somebody else opened")
    func shutdownLeavesOthersWindows() async {
        let daemon = FakeSyncDaemon(document: Fixture.document(pairingPort: 5555))
        let log = EventLog()
        let link = await Self.link(daemon, log)

        link.refreshIfIdle()
        _ = await log.waitFor(1)
        await link.shutdown()

        let calls = await daemon.calls
        #expect(calls.contains("start closePairing") == false)
        #expect(log.all.last == .shutDown)
    }

    @Test("a shutdown sent right behind an open waits for it, then closes what it opened")
    func shutdownKeepsTheOrderItWasGiven() async {
        let daemon = FakeSyncDaemon(document: Fixture.document(pairingPort: 5555))
        let log = EventLog()
        let link = await Self.link(daemon, log)

        link.perform(.openPairingWindow)
        await link.shutdown()

        let calls = await daemon.calls
        let expected = [
            "start openPairing", "end openPairing", "start peers", "end peers",
            "start closePairing", "end closePairing",
        ]
        #expect(calls == expected)
    }

    @Test("a code this window dialled and nobody answered is refused on the way out")
    func shutdownRefusesAnUnansweredDial() async {
        let daemon = FakeSyncDaemon(document: Fixture.document([Fixture.nearby()]))
        let log = EventLog()
        let link = await Self.link(daemon, log)

        link.perform(.pair(deviceID: Fixture.deckID))
        await link.shutdown()

        let calls = await daemon.calls
        #expect(calls.contains("start confirmPairing"))
        #expect(log.all.last == .shutDown)
    }

    /// Emits `proposal` once and waits until the link has reported it, or five
    /// seconds pass. The stream buffers, so one emission reaches a watch that
    /// subscribes late.
    static func dialIn(
        _ proposal: PairingProposalDocument,
        on daemon: FakeSyncDaemon,
        log: EventLog
    ) async -> Bool {
        await daemon.emit(proposal)
        for _ in 0..<500 {
            if log.all.contains(.pairingRequested(proposal)) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    static func refusals(on daemon: FakeSyncDaemon) async -> Int {
        await daemon.calls.filter { $0 == "start confirmPairing" }.count
    }

    /// The pairing dialog goes down with the window, and nothing else answers
    /// the peer that is waiting on it.
    @Test("a peer that dialled in and was never answered is refused on the way out")
    func shutdownRefusesAnUnansweredPeer() async {
        let daemon = FakeSyncDaemon(document: Fixture.document([Fixture.nearby()]))
        let log = EventLog()
        let link = await Self.link(daemon, log)

        #expect(await Self.dialIn(Fixture.proposal(), on: daemon, log: log))
        await link.shutdown()

        #expect(await Self.refusals(on: daemon) == 1)
        #expect(log.all.last == .shutDown)
    }

    @Test("…but not one that was answered, and not another client's dial")
    func shutdownLeavesAnsweredAndForeignProposals() async {
        let daemon = FakeSyncDaemon(document: Fixture.document([Fixture.nearby()]))
        let log = EventLog()
        let link = await Self.link(daemon, log)

        #expect(await Self.dialIn(Fixture.proposal(), on: daemon, log: log))
        link.perform(.answer(deviceID: Fixture.deckID, accept: true))
        let foreign = Fixture.proposal(
            Fixture.laptopID, name: "Laptop", direction: PairingProposalDocument.Direction.outgoing)
        #expect(await Self.dialIn(foreign, on: daemon, log: log))
        await link.shutdown()

        // The one confirmation is the answer itself.
        #expect(await Self.refusals(on: daemon) == 1)
        #expect(log.all.last == .shutDown)
    }

    @Test("a peer dialling in is reported as it happens")
    func pairingRequestsAreForwarded() async {
        let daemon = FakeSyncDaemon(document: Fixture.document())
        let log = EventLog()
        let link = await Self.link(daemon, log)

        let proposal = Fixture.proposal()
        // The watch subscribes asynchronously; keep offering until it is heard.
        var heard = false
        for _ in 0..<100 where !heard {
            await daemon.emit(proposal)
            try? await Task.sleep(for: .milliseconds(20))
            heard = log.all.contains(.pairingRequested(proposal))
        }
        #expect(heard)
        await link.shutdown()
    }
}
