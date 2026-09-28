import Foundation
import SkrepkaIPC
import SkrepkaSync

/// What `skrepka doctor` says when paired peers cannot reach this device.
///
/// Split from `Daemon+Diagnostics.swift`, which is about what this machine can
/// measure of itself; this is the one finding that is about what other
/// machines cannot do, read off their silence. See ``InboundSilence``.
extension Daemon {
    /// One line naming every paired peer that this device reaches and that
    /// has not connected back, with how to open this machine's firewall.
    func silentPeerProblems(now: Date) -> [String] {
        let silent = InboundSilence.silentPeers(
            progress: progress,
            sighted: Set(sighted.keys),
            dialledIn: peersThatDialledIn,
            now: now
        )
        guard !silent.isEmpty else { return [] }
        let names = silent.map { progress[$0]?.name ?? $0.fingerprint }.sorted().joined(separator: ", ")
        let ports = portsOtherDevicesDial()
        let advice = FirewallAdvice.current().remedy(opening: ports)
        return [
            """
            Paired devices this one reaches have not connected back: \(names). Nothing copied \
            on them reaches this clipboard, and their history arrives only when this device \
            asks for it. A firewall here is the usual cause — other devices need \
            \(FirewallAdvice.describe(ports)) and UDP 5353. \(advice)
            """
        ]
    }

    /// The ports a peer dials: the pinned listener's as bound, and the port
    /// the pairing listener asks for. Lowest first, and never `0` — a port
    /// the kernel picks anew each time is one no rule can name.
    func portsOtherDevicesDial() -> [Int] {
        let sync = syncServer?.port ?? listenerPorts.sync
        return Set([sync, listenerPorts.pairing]).filter { $0 != 0 }.sorted()
    }
}
