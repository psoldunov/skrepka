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
        /// `LivePushChoice.rawValue`, or `nil` where the user has expressed no
        /// preference and design §3's platform default decides.
        ///
        /// A column for the same reason ``highestProtocolSeen`` is one: the rest
        /// of this record is the pinning material, written once at pairing, and
        /// this is written whenever the user flips a switch. It is stored beside
        /// the peer rather than in preferences so that forgetting the peer
        /// forgets the choice — an override keyed by device identifier in
        /// `UserDefaults` would outlive the pairing and silently re-apply if the
        /// same machine ever paired again.
        ///
        /// Decoded tolerantly, like ``platformRaw``: a value written by a newer
        /// build reads as "no preference" rather than failing the row.
        var livePushChoiceRaw: String?

        init(
            deviceIDHex: String,
            deviceName: String,
            platformRaw: String,
            certificateDER: Data,
            pairedAt: Date,
            highestProtocolSeen: Int?,
            livePushChoiceRaw: String? = nil
        ) {
            self.deviceIDHex = deviceIDHex
            self.deviceName = deviceName
            self.platformRaw = platformRaw
            self.certificateDER = certificateDER
            self.pairedAt = pairedAt
            self.highestProtocolSeen = highestProtocolSeen
            self.livePushChoiceRaw = livePushChoiceRaw
        }
    }

#endif
