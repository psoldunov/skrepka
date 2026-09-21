import Foundation
import SkrepkaSync

/// The two names skrepkad claims when it publishes by itself.
///
/// **The host name is not the machine's.** `steamdeck.local` belongs to
/// whatever answers for the machine — avahi, when its address publishing is on
/// — and a second responder claiming it would be a conflict on the machine's
/// own name. skrepkad claims `skrepka-<first 8 hex digits of the device
/// ID>.local` instead: a name nothing else has a reason to hold, which is also
/// why probing for it is close to a formality. The SRV record points at it,
/// and a peer dials the name it resolves to.
///
/// **The instance name is the display name**, as avahi would publish it, and
/// renamed the way avahi renames — `steamdeck`, `steamdeck #2` — when another
/// device already holds it. Two Steam Decks out of the box are both called
/// `steamdeck`, so that is the ordinary case.
enum MDNSNaming {
    static let hostPrefix = "skrepka-"
    static let hostIDDigits = 8

    static func hostLabel(for deviceID: SyncDeviceID, attempt: Int) -> String {
        let base = hostPrefix + deviceID.hex.prefix(hostIDDigits).lowercased()
        return attempt > 1 ? "\(base)-\(attempt)" : base
    }

    /// An empty display name asks the responder to choose (see
    /// ``SkrepkaSync/ServiceDescriptor/displayName``), and the host label is
    /// this responder's choice.
    static func instanceLabel(for descriptor: ServiceDescriptor, attempt: Int) -> String {
        let base =
            descriptor.displayName.isEmpty
            ? hostLabel(for: descriptor.deviceID, attempt: 1) : descriptor.displayName
        guard attempt > 1 else { return base }
        let suffix = " #\(attempt)"
        return clamped(base, toBytes: DNSName.maximumLabelBytes - suffix.utf8.count) + suffix
    }

    /// Truncated on a character boundary, so a rename never splits a
    /// character into bytes that are not text.
    static func clamped(_ text: String, toBytes limit: Int) -> String {
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= limit else { break }
            kept.append(character)
            bytes += size
        }
        return kept
    }
}
