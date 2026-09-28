import Foundation
import SkrepkaSync

/// Paired peers this device reaches, and that never reach it.
///
/// The one sign of a firewall on this machine that this machine can see. A
/// firewall that drops inbound connections drops them before any socket
/// exists, so the daemon hears nothing at all — but every paired peer runs a
/// link of its own that dials this device, and retries at least once a minute
/// while that fails (`PeerLink.retryDelays`). A peer this device has been
/// exchanging with for minutes that has never once dialled in is being stopped
/// on the way in.
///
/// It costs one direction, and quietly. This device's own exchanges still pull
/// the peer's history every thirty seconds, so the peer list reads "synced";
/// what stops is everything the peer *sends* — live push rides the pushing
/// device's own link, so nothing copied there reaches this clipboard. That is
/// how a NixOS machine behind its default firewall looked healthy from every
/// angle it could check while a paired Mac's copies never arrived.
enum InboundSilence {
    /// How long after this device's first exchange with a peer the peer gets
    /// to dial in before its silence counts.
    ///
    /// A peer whose link had been failing waits out its longest retry delay,
    /// sixty seconds, before a ten-second connect timeout; three minutes is two
    /// of those rounds and then some.
    static let grace: TimeInterval = 180

    /// The peers that are on the network, that this device has been exchanging
    /// with for at least ``grace``, and that have not dialled in once.
    static func silentPeers(
        progress: [SyncDeviceID: PeerProgress],
        sighted: Set<SyncDeviceID>,
        dialledIn: Set<SyncDeviceID>,
        now: Date
    ) -> [SyncDeviceID] {
        progress.compactMap { deviceID, entry in
            guard sighted.contains(deviceID), !dialledIn.contains(deviceID),
                let first = entry.firstSyncedAt, now.timeIntervalSince(first) >= grace
            else { return nil }
            return deviceID
        }
    }
}
