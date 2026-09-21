import Foundation
import Logging
import NIOCore

/// What the announcer does with a packet from the link.
extension MDNSAnnouncer {
    /// RFC 6762 §6: a response carrying shared records "MUST" wait a random
    /// 20–120 ms, so the several hosts answering one browse do not all answer
    /// in the same instant. One carrying only unique records goes at once.
    static let sharedAnswerDelay = 20...120

    func receive(_ packet: MDNSSocket.Packet, on index: Int) async {
        guard phase != .idle, let message = try? DNSReader.decode(packet.bytes) else {
            // A packet this reader cannot parse is someone else's business —
            // the link carries every mDNS stack's traffic, and one malformed
            // or unusual packet is no reason to log anything.
            return
        }
        if message.isResponse {
            // RFC 6762 §6 and §11: a response from any source port but 5353
            // "MUST be silently ignored" — it is not a Multicast DNS response,
            // and must not be able to push this host off its name.
            guard packet.source.port == MDNSAnswering.port else { return }
            consider(message)
        } else if phase == .established {
            await answer(message, from: packet.source, on: index)
        }
    }

    /// RFC 6762 §8.1 while probing, §9 once established. See ``MDNSConflict``.
    private func consider(_ response: DNSMessage) {
        guard let everything = records(on: nil),
            MDNSConflict.isConflicting(response, with: everything, probing: phase == .probing)
        else { return }
        guard phase == .established else {
            probeWindow = probeWindow.noting(conflict: true)
            return
        }
        // §9: "the host MUST immediately reset its conflicted unique records
        // to probing state, and then conflict resolution proceeds by choosing
        // a new name". No goodbye for the old records: the name is now the
        // other host's, and a goodbye would tell every cache to drop *its*
        // records too.
        logger.notice("another device took this device's mDNS name; renaming")
        announcing?.cancel()
        attempt += 1
        // Probing before the task starts, so a second conflicting packet
        // arriving meanwhile counts against the probe rather than starting
        // another rename. In a task, because this runs on a socket's reader,
        // and a reader waiting out its own probe could not hear the answers.
        phase = .probing
        reprobe?.cancel()
        let run = generation
        reprobe = Task { [weak self] in await self?.rename(in: run) }
    }

    /// Probes for the next free name and announces it — unless the run it
    /// began in has been stopped or restarted meanwhile, in which case it
    /// does nothing at all.
    private func rename(in run: Int) async {
        do {
            try await claimNames()
            guard run == generation, !Task.isCancelled else { return }
            announceEverywhere()
        } catch MDNSAnnouncerError.namesTaken(let attempts) {
            guard run == generation else { return }
            logger.warning(
                "skrepkad's own mDNS responder could not find a free name; this device is not published",
                metadata: ["attempts": "\(attempts)"])
            lossSink.yield(.namesTaken(attempts: attempts))
        } catch {
            // Cancelled: a stop or a restart superseded this rename, and owns
            // what happens next.
            return
        }
    }

    private func answer(_ query: DNSMessage, from source: SocketAddress, on index: Int) async {
        guard let socket = sockets[index], let records = records(on: socket.interface) else { return }
        let recent = lastMulticast[index].map { .now - $0 < Self.recentMulticastWindow } ?? false
        let replies = MDNSAnswering.replies(
            to: query, fromPort: source.port ?? 0, records: records, multicastRecently: recent)
        for reply in replies {
            if reply.message.answers.contains(where: { !$0.cacheFlush }) {
                // Cancelled only when the announcer is stopping, and then an
                // answer sent a little early is harmless.
                try? await Task.sleep(for: .milliseconds(Int.random(in: Self.sharedAnswerDelay)))
            }
            await deliver(reply, to: source, over: socket, index: index)
        }
    }

    private func deliver(
        _ reply: MDNSAnswering.Reply, to source: SocketAddress, over socket: MDNSSocket, index: Int
    ) async {
        let bytes = DNSWriter.encode(reply.message)
        do {
            if reply.isUnicast {
                try await socket.send(bytes, to: source)
            } else {
                try await socket.sendMulticast(bytes)
                lastMulticast[index] = .now
            }
        } catch {
            logger.notice(
                "an mDNS answer could not be sent",
                metadata: ["interface": "\(socket.interface.name)", "reason": "\(error)"])
        }
    }
}
