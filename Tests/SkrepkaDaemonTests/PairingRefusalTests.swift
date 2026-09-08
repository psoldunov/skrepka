import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// The one outcome ``PendingPairing`` says the design must not have: a pairing
/// accepted because nobody was watching.
///
/// `skrepkad` runs under systemd and `skrepka pair` may never be typed, so
/// every path through ``Daemon/confirmPairing(_:direction:)`` has to end in a
/// `false` by itself. Nothing asserted that until this file.
///
/// The deadline is injected — `Daemon(… pairingAnswerTimeout:)` — because the
/// production one is two minutes and a suite that sleeps for it is a suite
/// nobody runs.
@Suite("Pairing refuses by default")
struct PairingRefusalTests {
    /// How long a test waits for something that should already have happened.
    static let patience: Duration = .seconds(5)

    static func daemon(answering timeout: Duration) throws -> Daemon {
        var options = DaemonOptions()
        options.syncEnabled = false
        options.dataDirectory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-pairing-\(UUID().uuidString)", directoryHint: .isDirectory)
        return try Daemon(options: options, environment: [:], pairingAnswerTimeout: timeout)
    }

    /// A proposal from a device whose certificate is `seed` repeated. The bytes
    /// never reach a TLS stack here — only their hash, which is the device
    /// identifier the daemon keys `pending` by.
    static func proposal(seed: UInt8) -> PairingProposal {
        PairingProposal(
            peer: PairedPeer(
                certificateDER: Data(repeating: seed, count: 32),
                deviceName: "peer-\(seed)",
                platform: .macos,
                pairedAt: Date()
            ),
            shortAuthenticationString: "A3F2-91BC"
        )
    }

    /// Waits until the daemon holds `count` proposals, so a test acts on a
    /// parked wait rather than racing one that has not parked yet.
    static func waitForPending(_ daemon: Daemon, count: Int) async throws {
        let deadline = ContinuousClock.now + Self.patience
        while await daemon.pendingProposals().count != count {
            guard ContinuousClock.now < deadline else {
                Issue.record("the daemon never held \(count) pending proposal(s)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("nobody answers, so the answer is no")
    func refusesWhenNobodyAnswers() async throws {
        let daemon = try Self.daemon(answering: .milliseconds(200))
        let accepted = await daemon.confirmPairing(
            Self.proposal(seed: 1), direction: PairingDirection.incoming)
        #expect(accepted == false)
        // And the daemon does not keep holding it afterwards, which is what a
        // dropped continuation would have looked like from outside.
        #expect(await daemon.pendingProposals().isEmpty)
    }

    @Test("a second proposal from the same device expires the first")
    func aRetryExpiresTheProposalItReplaces() async throws {
        // Long enough that a first proposal timing out on its own would fail
        // the elapsed-time assertion below rather than pass it by accident.
        let daemon = try Self.daemon(answering: .seconds(60))
        let proposal = Self.proposal(seed: 2)

        async let first = daemon.confirmPairing(proposal, direction: PairingDirection.incoming)
        try await Self.waitForPending(daemon, count: 1)

        let retry = Task { await daemon.confirmPairing(proposal, direction: PairingDirection.incoming) }
        let started = ContinuousClock.now
        let firstAnswer = await first
        let elapsed = ContinuousClock.now - started

        #expect(firstAnswer == false)
        #expect(elapsed < Self.patience)

        // The retry is still answerable, which is the point of replacing the
        // proposal rather than refusing the second dial.
        try await Self.waitForPending(daemon, count: 1)
        #expect(await daemon.answerPairing(deviceID: proposal.peer.deviceID, accept: false))
        #expect(await retry.value == false)
    }

    @Test("answering a device with nothing pending says so")
    func answeringNothingReportsFalse() async throws {
        let daemon = try Self.daemon(answering: .milliseconds(200))
        let deviceID = Self.proposal(seed: 3).peer.deviceID
        #expect(await daemon.answerPairing(deviceID: deviceID, accept: true) == false)
    }

    @Test("an answered proposal is accepted, and only that one")
    func anAnsweredProposalIsAccepted() async throws {
        let daemon = try Self.daemon(answering: .seconds(60))
        let proposal = Self.proposal(seed: 4)

        async let waiting = daemon.confirmPairing(proposal, direction: PairingDirection.incoming)
        try await Self.waitForPending(daemon, count: 1)
        #expect(await daemon.answerPairing(deviceID: proposal.peer.deviceID, accept: true))
        #expect(await waiting)
        // Answering the same device twice is not a second yes.
        #expect(await daemon.answerPairing(deviceID: proposal.peer.deviceID, accept: true) == false)
    }
}
