import Foundation
import SkrepkaIPC
import SkrepkaSync

/// Turning the short string a user types into exactly one device — or into
/// nothing.
///
/// Split out of `Daemon+Actions.swift` because the two selectors here are one
/// subject and that file was at its line limit; the matching rule is also the
/// one place a mistake un-pairs the wrong machine, so it is worth reading on
/// its own.
extension Daemon {
    /// Forgets a paired device.
    public func unpair(fingerprint: String) async -> ActionDocument {
        guard let wanted = Self.selector(fingerprint) else {
            return .refused(Self.blankSelectorDetail)
        }
        let paired: [PairedPeer]
        do {
            paired = try await trust.pairedPeers()
        } catch {
            // Surfaced rather than discarded: an empty list here reads as "no
            // paired device matches that", which is a different answer from
            // "the store could not be read" and sends the user hunting for a
            // fingerprint that is fine.
            return .refused("could not read the paired devices: \(error)")
        }
        let matches =
            paired.filter { $0.deviceID.hex.hasPrefix(wanted) }
            + paired.filter { $0.deviceID.fingerprint.lowercased() == wanted }
        guard let peer = Set(matches.map(\.deviceID)).count == 1 ? matches.first : nil else {
            return matches.isEmpty
                ? .refused("no paired device matches \"\(fingerprint)\"")
                : .refused("\"\(fingerprint)\" matches more than one paired device")
        }
        do {
            try await trust.forgetPairedPeer(peer.deviceID)
        } catch {
            return .refused("could not forget it: \(error)")
        }
        await pairedSetMayHaveChanged()
        return .succeeded("forgot \(peer.deviceName)", subject: peer.deviceID.fingerprint)
    }

    static func sighting(
        matching fingerprint: String,
        in sighted: [SyncDeviceID: Sighting]
    ) -> Sighting? {
        guard let wanted = selector(fingerprint) else { return nil }
        let matches = sighted.filter {
            $0.key.hex.hasPrefix(wanted) || $0.key.fingerprint.lowercased() == wanted
        }
        // Exactly one, or nothing. Pairing with whichever of two peers a short
        // prefix happened to hit is the one mistake this whole handshake exists
        // to make impossible.
        return matches.count == 1 ? matches.values.first : nil
    }

    /// The lowercased selector, or nil when there is nothing to select with.
    ///
    /// **Blank is not a wildcard.** `hasPrefix("")` is true of every string, so
    /// an empty or whitespace-only selector matched the whole paired set and the
    /// whole sighted set — `skrepka unpair ""` forgot the only paired peer, and
    /// `skrepka pair --peer ""` dialled whichever device happened to be visible.
    /// Refused here, in the daemon, rather than only in the CLI: any client on
    /// the session bus can call these members, so this is where the rule has to
    /// hold.
    static func selector(_ fingerprint: String) -> String? {
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    static let blankSelectorDetail = """
        name a device to act on. An empty fingerprint would match every one of \
        them. Run `skrepka peers` to see the fingerprints.
        """
}
