import Foundation
import SkrepkaIPC

/// `skrepka peers`, rendered for a person.
///
/// This device first, because half of what the command is for is reading this
/// machine's own fingerprint out loud to somebody standing at the other one.
/// Then paired devices, then ones merely visible on the network — the same
/// order ``PeersDocument/peers`` arrives in, kept rather than re-sorted.
public enum PeersReport {
    public static func text(_ document: PeersDocument, timeZone: TimeZone = .current) -> String {
        var lines = local(document)
        let paired = document.peers.filter(\.isPaired)
        let sighted = document.peers.filter { !$0.isPaired }
        lines += section("PAIRED", paired, empty: "  none yet — run `skrepka pair`", timeZone: timeZone)
        lines += section("ON THE NETWORK", sighted, empty: "  nothing else in sight", timeZone: timeZone)
        return lines.joined(separator: "\n")
    }

    private static func local(_ document: PeersDocument) -> [String] {
        let pairing =
            document.pairingPort.map { "accepting pairings on port \($0)" }
            ?? "not accepting pairings"
        return [
            "THIS DEVICE",
            "  name         \(document.localName)",
            "  fingerprint  \(document.localFingerprint)",
            "  pairing      \(pairing)",
            "",
        ]
    }

    private static func section(
        _ title: String,
        _ peers: [PeerDocument],
        empty: String,
        timeZone: TimeZone
    ) -> [String] {
        var lines = [title]
        if peers.isEmpty {
            lines.append(empty)
        } else {
            lines += peers.flatMap { entry($0, timeZone: timeZone) }
        }
        lines.append("")
        return lines
    }

    private static func entry(_ peer: PeerDocument, timeZone: TimeZone) -> [String] {
        var lines = [
            "  \(peer.name ?? "unnamed")  (\(peer.fingerprint))  \(peer.platform)"
        ]
        lines.append("    link        \(peer.linkState)\(peer.isSighted ? "" : ", not in sight")")
        if peer.isPaired {
            lines.append("    live push   \(peer.livePush ? "on" : "off")")
            lines.append("    last sync   \(synced(peer, timeZone: timeZone))")
        } else if peer.isAcceptingPairing {
            lines.append("    pairing     open — `skrepka pair --peer \(peer.fingerprint)`")
        }
        return lines
    }

    private static func synced(_ peer: PeerDocument, timeZone: TimeZone) -> String {
        guard let last = peer.lastSyncedAt else { return "not this run" }
        return HistoryReport.stamp(last, in: timeZone)
    }

}
