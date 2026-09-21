import Foundation
import Logging
import SkrepkaSync

/// Probing for the two names (RFC 6762 §8.1) and announcing them (§8.3).
extension MDNSAnnouncer {
    /// §8.1: "250 ms after the first query, the host should send a second;
    /// then, 250 ms after that, a third", and the name is free if nothing
    /// conflicting has arrived 250 ms after the third.
    static let probeCount = 3
    static let probeInterval: Duration = .milliseconds(250)
    /// §8.1: "If fifteen conflicts occur within any ten-second period, then
    /// the host MUST wait at least five seconds before each successive
    /// additional probe attempt" — and "a valid way to comply … is to always
    /// wait five seconds after any failed probe attempt". Only reached from the
    /// sixth attempt, by which point this is a network with a naming problem.
    static let slowProbeAfter = 5
    static let slowProbeDelay: Duration = .seconds(5)
    /// §8.3: at least two announcements a second apart, the interval at least
    /// doubling. Three, at 0, 1 and 3 seconds.
    static let announcementGaps: [Duration] = [.seconds(1), .seconds(2)]

    /// Probes under successive names until one draws no conflict.
    ///
    /// Throws `CancellationError` when a stop or restart overtook it, so a probe
    /// that was already waiting cannot claim the names for a run that is over.
    func claimNames() async throws {
        let run = generation
        while attempt <= Self.nameAttempts {
            let isFree = try await probeOnce()
            guard run == generation else { throw CancellationError() }
            if isFree {
                phase = .established
                logger.info(
                    "publishing this device with skrepkad's own mDNS responder",
                    metadata: ["name": "\(registration?.name ?? "")", "attempt": "\(attempt)"])
                return
            }
            logger.notice("the name is taken; trying the next one", metadata: ["attempt": "\(attempt)"])
            attempt += 1
            if attempt > Self.slowProbeAfter { try await Task.sleep(for: Self.slowProbeDelay) }
        }
        phase = .idle
        throw MDNSAnnouncerError.namesTaken(attempts: Self.nameAttempts)
    }

    /// One round of three probes. True when nobody defended either name.
    ///
    /// A machine with no interface yet has nobody to ask, and the names are
    /// device-derived: it takes them and lets §9 settle anything later, rather
    /// than refusing to publish until a network appears.
    private func probeOnce() async throws -> Bool {
        phase = .probing
        probeWindow = .closed
        // §8.1: "first wait for a short random delay time, uniformly
        // distributed in the range 0-250 ms".
        try await Task.sleep(for: .milliseconds(Int.random(in: 0...250)))
        // §8.1: responses "received *before* the first probe packet is sent
        // MUST be silently ignored" — so the window opens only now.
        probeWindow = .opened
        for _ in 0..<Self.probeCount {
            await sendEverywhere { $0.probe() }
            try await Task.sleep(for: Self.probeInterval)
            if probeWindow.sawConflict { return false }
        }
        return !probeWindow.sawConflict
    }

    /// Announces on every interface.
    func announceEverywhere() {
        announcing?.cancel()
        announcing = Task { [weak self] in
            await self?.announcementRound(on: nil)
        }
    }

    /// Probes, then announces, on one link that appeared or changed after the
    /// names were claimed — RFC 6762 §8: every link change starts again at
    /// probing, because the new link may hold a host already using the name.
    ///
    /// A defence arriving here is judged by the established rules (§9) rather
    /// than §8.1's any-type rule, and wins the same way: it renames this host
    /// everywhere, which also ends this round, since the attempt it began
    /// under is gone.
    func joinLink(_ index: Int) {
        linkRounds[index]?.cancel()
        let run = generation
        let claimed = attempt
        linkRounds[index] = Task { [weak self] in
            await self?.probeThenAnnounce(on: index, run: run, attempt: claimed)
        }
    }

    private func probeThenAnnounce(on index: Int, run: Int, attempt claimed: Int) async {
        do {
            try await Task.sleep(for: .milliseconds(Int.random(in: 0...250)))
            for _ in 0..<Self.probeCount {
                await send(on: index) { $0.probe() }
                try await Task.sleep(for: Self.probeInterval)
            }
        } catch {
            return
        }
        guard run == generation, attempt == claimed, phase == .established else { return }
        await announcementRound(on: index)
    }

    private func announcementRound(on index: Int?) async {
        for gap in [Duration.zero] + Self.announcementGaps {
            do {
                try await Task.sleep(for: gap)
            } catch {
                return
            }
            guard phase == .established else { return }
            if let index {
                await send(on: index) { $0.announcement() }
            } else {
                await sendEverywhere { $0.announcement() }
            }
        }
    }

    /// Sends one multicast message per interface, each built from that
    /// interface's records.
    func sendEverywhere(_ message: (MDNSServiceRecords) -> DNSMessage) async {
        for index in sockets.keys { await send(on: index, message) }
    }

    func send(on index: Int, _ message: (MDNSServiceRecords) -> DNSMessage) async {
        guard let socket = sockets[index], let records = records(on: socket.interface) else { return }
        let built = message(records)
        do {
            try await socket.sendMulticast(DNSWriter.encode(built))
            if built.isResponse { lastMulticast[index] = .now }
        } catch {
            logger.notice(
                "an mDNS packet could not be sent",
                metadata: ["interface": "\(socket.interface.name)", "reason": "\(error)"])
        }
    }
}
