// SwiftData is the macOS persistence engine and stays that way (D-3, D-9). Linux
// gets a separate SQLite conformance of HistoryStoring in Phase 4 storage work,
// not a second @Model.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData

    /// The persisted shape of one paired peer — the macOS backing store for
    /// `SkrepkaSync.TrustStore`, which declares the surface and deliberately owns
    /// none of the storage.
    ///
    /// It holds the peer's certificate because that is the pinning material: TLS
    /// compares a peer's leaf against the hash of these bytes and nothing else. A
    /// peer certificate is public, unlike this device's own private key, which
    /// stays in the Keychain behind `TrustStore.localIdentity()`.
    ///
    /// ``highestProtocolSeen`` is a column rather than part of `PairedPeer` for
    /// the reason `TrustStore` gives: the rest of the record is written once at
    /// pairing, the mark is written on every connection, and folding them together
    /// would mean a read-modify-write of the whole record per handshake.
    ///
    /// No `@Attribute(.unique)` on ``deviceIDHex``. `ClipRecord.contentHash` is
    /// not unique-constrained either and `recordMatching(contentHash:)` does that
    /// lookup by hand; one row-identity mechanism in this store, not two.
    @Model
    final class PairedDeviceRecord {
        /// `SyncDeviceID.hex`. The lookup key, and a denormalisation of
        /// ``certificateDER`` — `PairedDeviceMapping` refuses a row where the two
        /// disagree rather than trusting either one.
        var deviceIDHex: String = ""
        /// What the user sees. Advisory: the peer may change it, and it is never
        /// an identity.
        var deviceName: String = ""
        /// `PeerPlatform.rawValue`. Decoded tolerantly — a value this build has
        /// never heard of maps to `.unknown` rather than failing the row.
        var platformRaw: String = PeerPlatform.unknown.rawValue
        /// The certificate shown at pairing time, DER.
        var certificateDER: Data = Data()
        var pairedAt: Date = Date()
        /// `ProtocolVersion.rawValue`, highest ever advertised by this peer, or
        /// `nil` if it has never connected. Only ever raised — see
        /// `HistoryStore.recordProtocolVersion(_:for:)`.
        var highestProtocolSeen: Int?

        init(
            deviceIDHex: String,
            deviceName: String,
            platformRaw: String,
            certificateDER: Data,
            pairedAt: Date,
            highestProtocolSeen: Int?
        ) {
            self.deviceIDHex = deviceIDHex
            self.deviceName = deviceName
            self.platformRaw = platformRaw
            self.certificateDER = certificateDER
            self.pairedAt = pairedAt
            self.highestProtocolSeen = highestProtocolSeen
        }
    }

#endif
