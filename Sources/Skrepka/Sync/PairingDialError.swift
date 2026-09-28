import Foundation
import SkrepkaSync

/// A dial to pair that never reached the device, with what this Mac knows
/// about where it was dialling.
///
/// Carried rather than rebuilt at the catch because the sentence needs it: a
/// Linux machine that does not answer is almost always behind its own firewall
/// — NixOS ships one on and dropping — and the only useful thing to tell the
/// user is which ports to open on it, which only the resolved record knows.
///
/// `nonisolated` against the app target's default main-actor isolation, like
/// ``SyncFailureText``, which reads it from wherever the failure lands.
nonisolated struct PairingDialError: Error, CustomStringConvertible {
    let failure: DialFailure
    let peerName: String
    let platform: PeerPlatform
    /// The port that was dialled.
    let pairingPort: UInt16
    /// The port the device syncs on once paired, from its SRV record.
    let syncPort: UInt16
    /// NIO's own description, for the log.
    let reason: String

    var description: String {
        "could not reach \(peerName) on port \(pairingPort) (sync \(syncPort)): \(reason)"
    }
}
