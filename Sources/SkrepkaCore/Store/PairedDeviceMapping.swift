// Maps the SwiftData PairedDeviceRecord, so it belongs to that conformance. The
// Linux SQLite store writes its own mapping in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync

    /// Conversions between the persisted ``PairedDeviceRecord`` and
    /// `SkrepkaSync.PairedPeer`.
    enum PairedDeviceMapping {
        /// `nil` when the row cannot be trusted to name its own peer.
        ///
        /// `PairedPeer` derives `deviceID` from the certificate, so a row whose
        /// stored identifier disagrees with its stored certificate would be
        /// returned under an identifier that never signed those bytes — a pin that
        /// does not match what it pins. There is no repair for that: substituting
        /// either half would authenticate a device on the strength of the other.
        /// The caller logs and skips.
        static func peer(from record: PairedDeviceRecord) -> PairedPeer? {
            let peer = PairedPeer(
                certificateDER: record.certificateDER,
                deviceName: record.deviceName,
                // `PeerPlatform.init(wireValue:)` tolerates a value this build has
                // never heard of, which is what a row written by a newer build
                // looks like.
                platform: PeerPlatform(wireValue: record.platformRaw),
                pairedAt: record.pairedAt
            )
            guard peer.deviceID.hex == record.deviceIDHex else { return nil }
            return peer
        }

        static func makeRecord(from peer: PairedPeer) -> PairedDeviceRecord {
            PairedDeviceRecord(
                deviceIDHex: peer.deviceID.hex,
                deviceName: peer.deviceName,
                platformRaw: peer.platform.rawValue,
                certificateDER: peer.certificateDER,
                pairedAt: peer.pairedAt,
                highestProtocolSeen: nil
            )
        }

        /// Rewrites an existing row in place, keeping its ``PairedDeviceRecord``
        /// identity so anything already holding the object sees the update.
        ///
        /// ``PairedDeviceRecord/highestProtocolSeen`` is untouched. Re-pairing must
        /// not reset the anti-downgrade mark, or forcing one re-pair would be
        /// enough to erase it.
        ///
        /// ``PairedDeviceRecord/livePushChoiceRaw`` is untouched too, for a
        /// gentler reason: a peer re-running the pairing exchange — a reinstall,
        /// a second confirmation — is the same machine the user already made a
        /// decision about, and silently re-enabling live push on it is the one
        /// direction of that mistake the user cannot see. Forgetting the peer is
        /// what clears the choice.
        static func update(_ record: PairedDeviceRecord, from peer: PairedPeer) {
            record.deviceIDHex = peer.deviceID.hex
            record.deviceName = peer.deviceName
            record.platformRaw = peer.platform.rawValue
            record.certificateDER = peer.certificateDER
            record.pairedAt = peer.pairedAt
        }
    }

#endif
