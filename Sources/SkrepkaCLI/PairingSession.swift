import Foundation
import SkrepkaIPC

/// `skrepka pair`, in both directions.
///
/// Dialling and accepting are one command because they are one task from the
/// user's side: two machines, one of which starts it. Which of the two this one
/// is depends only on whether `--peer` names a device that is already in sight.
struct PairingSession {
    let proxy: DaemonProxy

    func run(peer: String?, seconds: UInt32) async throws -> Int32 {
        if let peer {
            return try await dial(peer)
        }
        return try await accept(seconds: seconds)
    }

    // MARK: - This device dials

    private func dial(_ fingerprint: String) async throws -> Int32 {
        CLIConsole.say("Dialling \(fingerprint)…")
        // The daemon may take up to its own dial deadline to answer; the
        // default call timeout would give up a third of the way there.
        let proposal = try await proxy.withTimeout(SkrepkaBus.pairingCallTimeout).pair(with: fingerprint)
        return try await answer(proposal)
    }

    // MARK: - This device is dialled

    /// Subscribes *before* opening the window, on purpose: a peer already
    /// waiting for this device to start accepting can dial the moment the port
    /// is up, and a subscription added afterwards would miss that proposal and
    /// then wait out the whole window for a second one.
    private func accept(seconds: UInt32) async throws -> Int32 {
        let requests = try await proxy.pairingRequests()
        let window = try await proxy.openPairing(seconds: seconds)
        CLIConsole.say(
            """
            This device is accepting pairings on port \(window.port) until \
            \(HistoryReport.stamp(window.expiresAt, in: .current)).
            Run `skrepka pair --peer <this device's fingerprint>` on the other machine.
            \(Self.firewallHint(pairingPort: window.port))
            Waiting…
            """
        )
        guard let proposal = await first(from: requests, before: window.expiresAt) else {
            CLIConsole.say("No device asked to pair before the window closed.")
            // The window is closed either way once it expires; closing it here
            // covers the case where the wait ended for another reason, and the
            // member is idempotent.
            _ = try await proxy.closePairing()
            return 1
        }
        let code = try await answer(proposal)
        _ = try await proxy.closePairing()
        return code
    }

    /// What to do if the other machine says it could not connect.
    ///
    /// Said up front because the failure shows on the *other* screen: a
    /// firewall here drops the dial silently, so this side never learns it
    /// happened and would otherwise wait out the whole window saying nothing.
    /// Skrepka's own pair is named whole, because the peer dials the sync port
    /// straight after pairing; any other port is named alone.
    static func firewallHint(pairingPort: UInt16) -> String {
        let ports = Int(pairingPort) == SkrepkaPorts.pairing ? SkrepkaPorts.all : [Int(pairingPort)]
        return """
            If the other machine cannot connect, a firewall here is the usual cause: allow \
            \(FirewallAdvice.describe(ports)). \(FirewallAdvice.current().remedy(opening: ports))
            """
    }

    /// The first proposal, or nil once the window has expired.
    ///
    /// A race rather than a plain `for await`: the stream never ends by itself,
    /// so a CLI reading it without a deadline would sit there after the daemon
    /// had already stopped accepting.
    private func first(
        from requests: AsyncStream<PairingProposalDocument>,
        before deadline: Date
    ) async -> PairingProposalDocument? {
        await withTaskGroup(of: PairingProposalDocument?.self) { group in
            group.addTask {
                for await proposal in requests { return proposal }
                return nil
            }
            group.addTask {
                // Cancellation is the only way this throws, and cancellation is
                // this task losing the race — which the group handles.
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                return nil
            }
            // The group's own `next()` is doubly optional — no task left, versus
            // a task that finished with nothing — and both mean the same here.
            var winner: PairingProposalDocument?
            if let finished = await group.next() {
                winner = finished
            }
            group.cancelAll()
            return winner
        }
    }

    // MARK: - The human part

    private func answer(_ proposal: PairingProposalDocument) async throws -> Int32 {
        CLIConsole.say(PairingReport.text(proposal))
        let accepted = CLIConsole.confirm("Do these words match the other device?")
        let result = try await proxy.confirmPairing(deviceID: proposal.deviceID, accept: accepted)
        return CLIOutcome.report(result, whenSilent: accepted ? "Paired." : "Pairing refused.")
    }
}
