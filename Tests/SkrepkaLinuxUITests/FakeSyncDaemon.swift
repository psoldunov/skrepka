import Foundation
import SkrepkaIPC
import Synchronization

@testable import SkrepkaLinuxUI

/// A daemon that records every call and answers only when the test says.
///
/// A member put on ``hold(_:)`` suspends each caller until ``release(_:)``,
/// which is how a test gets an action to be in flight for as long as it needs
/// — the one thing a live daemon cannot be asked to do on demand.
actor FakeSyncDaemon: SyncDaemon {
    /// `start X` and `end X`, in the order they happened.
    private(set) var calls: [String] = []
    var document: PeersDocument
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let requests: AsyncStream<PairingProposalDocument>
    private let requestSink: AsyncStream<PairingProposalDocument>.Continuation

    init(document: PeersDocument = SyncFixtures.document()) {
        self.document = document
        (requests, requestSink) = AsyncStream<PairingProposalDocument>.makeStream()
    }

    func hold(_ member: String) {
        held.insert(member)
    }

    func release(_ member: String) {
        held.remove(member)
        for waiter in waiters.removeValue(forKey: member) ?? [] {
            waiter.resume()
        }
    }

    func setDocument(_ document: PeersDocument) {
        self.document = document
    }

    func emit(_ proposal: PairingProposalDocument) {
        requestSink.yield(proposal)
    }

    private func enter(_ member: String) async {
        calls.append("start \(member)")
        guard held.contains(member) else { return }
        await withCheckedContinuation { waiters[member, default: []].append($0) }
    }

    private func leave(_ member: String) {
        calls.append("end \(member)")
    }

    // MARK: - SyncDaemon

    func peers() async throws -> PeersDocument {
        await enter("peers")
        leave("peers")
        return document
    }

    func openPairing(seconds: UInt32) async throws -> PairingWindowDocument {
        await enter("openPairing")
        leave("openPairing")
        return PairingWindowDocument(port: 5555, expiresAt: SyncFixtures.now + 300)
    }

    func closePairing() async throws -> ActionDocument {
        await enter("closePairing")
        leave("closePairing")
        return .succeeded()
    }

    func pairWith(deviceID: String) async throws -> PairingProposalDocument {
        await enter("pairWith")
        leave("pairWith")
        return SyncFixtures.proposal(deviceID, direction: PairingProposalDocument.Direction.outgoing)
    }

    func confirmPairing(deviceID: String, accept: Bool) async throws -> ActionDocument {
        await enter("confirmPairing")
        leave("confirmPairing")
        return .succeeded(accept ? "paired" : "refused", subject: deviceID)
    }

    func unpair(fingerprint: String) async throws -> ActionDocument {
        await enter("unpair")
        leave("unpair")
        return .succeeded("forgot MacBook", subject: fingerprint)
    }

    func setLivePush(device: String, choice: String) async throws -> ActionDocument {
        await enter("setLivePush \(choice)")
        leave("setLivePush \(choice)")
        return .succeeded("live clipboard is \(choice)")
    }

    func syncNow() async throws -> ActionDocument {
        await enter("syncNow")
        leave("syncNow")
        return .succeeded("asked 1 peer to sync")
    }

    func pairingRequests() async throws -> AsyncStream<PairingProposalDocument> {
        requests
    }
}

/// Every event a link reported, in order, and a way to wait for more.
final class EventLog: Sendable {
    private let events = Mutex<[SyncEvent]>([])

    func append(_ event: SyncEvent) {
        events.withLock { $0.append(event) }
    }

    var all: [SyncEvent] {
        events.withLock { $0 }
    }

    /// The events, once there are at least `count` — or whatever there is when
    /// five seconds have passed, so a missing event fails the test rather than
    /// hanging it.
    func waitFor(_ count: Int) async -> [SyncEvent] {
        for _ in 0..<500 where all.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all
    }
}
