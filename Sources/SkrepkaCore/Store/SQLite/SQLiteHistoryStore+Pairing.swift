// The paired-peer surface of the Linux store. Raw SQLite is the Linux engine
// (D-3) and macOS never resolves the CSQLite target, so this is fenced to Linux.
#if os(Linux)

    import Foundation
    import Logging
    import SkrepkaSync

    /// The Linux backing store for `SkrepkaSync.TrustStore`, mirroring
    /// `HistoryStore+Pairing` method for method.
    ///
    /// The store does not conform to `TrustStore` itself for the same reason the
    /// macOS one does not: that protocol also owns this device's *private key*,
    /// which belongs in a credential store rather than a history database. Phase 6
    /// writes the Linux conformance that puts the two together.
    extension SQLiteHistoryStore {
        private static let columns = """
            device_id, device_name, platform_raw, certificate_der, paired_at, highest_protocol_seen
            """

        /// Every paired peer, oldest pairing first.
        public func pairedPeers() throws -> [PairedPeer] {
            var peers: [PairedPeer] = []
            var skipped = 0
            try database.query(
                "SELECT \(Self.columns) FROM paired_device ORDER BY paired_at ASC, rowid ASC"
            ) { statement in
                guard let peer = Self.peer(from: statement) else {
                    skipped += 1
                    return
                }
                peers.append(peer)
            }
            if skipped > 0 {
                SkrepkaLog.store.error(
                    "Skipped \(skipped) paired devices whose stored identifier does not match its certificate."
                )
            }
            return peers
        }

        public func pairedPeer(_ deviceID: SyncDeviceID) throws -> PairedPeer? {
            var peer: PairedPeer?
            try database.query(
                "SELECT \(Self.columns) FROM paired_device WHERE device_id = ?",
                [.value(deviceID.hex)]
            ) { statement in
                peer = Self.peer(from: statement)
            }
            return peer
        }

        /// Inserts or replaces the record for `peer.deviceID`, leaving that peer's
        /// protocol high-water mark alone.
        ///
        /// The mark is untouched on conflict because re-pairing must not reset it,
        /// or forcing one re-pair would be enough to erase the anti-downgrade
        /// evidence.
        public func savePairedPeer(_ peer: PairedPeer) throws {
            try database.run(
                """
                INSERT INTO paired_device (\(Self.columns))
                VALUES (?, ?, ?, ?, ?, NULL)
                ON CONFLICT(device_id) DO UPDATE SET device_name = excluded.device_name,
                                                     platform_raw = excluded.platform_raw,
                                                     certificate_der = excluded.certificate_der,
                                                     paired_at = excluded.paired_at
                """,
                [
                    .value(peer.deviceID.hex),
                    .value(peer.deviceName),
                    .value(peer.platform.rawValue),
                    .value(peer.certificateDER),
                    .value(peer.pairedAt),
                ]
            )
        }

        /// Forgets a peer and its high-water mark — a forgotten device is a
        /// stranger again, which is what makes re-pairing mean anything.
        ///
        /// Silent when it was not paired: unpairing twice is the same outcome as
        /// unpairing once.
        public func forgetPairedPeer(_ deviceID: SyncDeviceID) throws {
            try database.run(
                "DELETE FROM paired_device WHERE device_id = ?",
                [.value(deviceID.hex)]
            )
        }

        /// The highest protocol version this peer has ever advertised, or `nil` if
        /// it has never connected.
        ///
        /// Design §9's anti-downgrade rule compares against this: a peer that once
        /// spoke v2 and now advertises v1 is either an attacker stripping features
        /// or a rollback nobody asked for.
        public func highestProtocolVersion(for deviceID: SyncDeviceID) throws -> ProtocolVersion? {
            var version: ProtocolVersion?
            try database.query(
                "SELECT highest_protocol_seen FROM paired_device WHERE device_id = ?",
                [.value(deviceID.hex)]
            ) { statement in
                version = statement.integer(0).map(ProtocolVersion.init(rawValue:))
            }
            return version
        }

        /// Raises the mark when `version` is higher, and does nothing when it is
        /// not.
        ///
        /// **Never lowers it.** A store that lowered the mark would defeat the
        /// downgrade check silently — the handshake would keep comparing against a
        /// number an attacker had already talked it down to. `highest_protocol_seen
        /// IS NULL` is in the predicate rather than relying on `NULL < ?`, which is
        /// `NULL` in SQL and would leave a peer's first connection unrecorded.
        ///
        /// Does nothing for a peer that is not paired: there is no record to raise,
        /// and inventing one would create a trusted peer out of a connection
        /// attempt.
        public func recordProtocolVersion(
            _ version: ProtocolVersion,
            for deviceID: SyncDeviceID
        ) throws {
            try database.run(
                """
                UPDATE paired_device SET highest_protocol_seen = ?
                WHERE device_id = ? AND (highest_protocol_seen IS NULL OR highest_protocol_seen < ?)
                """,
                [.value(version.rawValue), .value(deviceID.hex), .value(version.rawValue)]
            )
        }

        /// The user's live-push choice for this peer, or
        /// ``LivePushChoice/followsPlatformDefault`` when they have made none —
        /// and the same answer for a device that is not paired, which has no
        /// row to have made one on.
        public func livePushChoice(for deviceID: SyncDeviceID) throws -> LivePushChoice {
            var stored: String?
            try database.query(
                "SELECT live_push_choice FROM paired_device WHERE device_id = ?",
                [.value(deviceID.hex)]
            ) { statement in
                stored = statement.text(0)
            }
            return LivePushChoice(storedValue: stored)
        }

        /// Records the user's choice, or clears it back to the platform default.
        ///
        /// Does nothing for a device that is not paired: the `WHERE` matches no
        /// row, and inventing one would turn a preference into a trusted peer.
        public func setLivePushChoice(
            _ choice: LivePushChoice,
            for deviceID: SyncDeviceID
        ) throws {
            try database.run(
                "UPDATE paired_device SET live_push_choice = ? WHERE device_id = ?",
                [.value(choice.storedValue), .value(deviceID.hex)]
            )
        }

        /// Reads a row selected as ``columns``.
        ///
        /// `nil` when the row cannot be trusted to name its own peer. `PairedPeer`
        /// derives `deviceID` from the certificate, so a row whose stored
        /// identifier disagrees with its stored certificate would be returned under
        /// an identifier that never signed those bytes — a pin that does not match
        /// what it pins. There is no repair for that: substituting either half
        /// would authenticate a device on the strength of the other.
        private static func peer(from statement: SQLiteStatement) -> PairedPeer? {
            guard let deviceIDHex = statement.text(0),
                let deviceName = statement.text(1),
                let platformRaw = statement.text(2),
                let certificateDER = statement.blob(3),
                let pairedAt = statement.date(4)
            else { return nil }

            let peer = PairedPeer(
                certificateDER: certificateDER,
                deviceName: deviceName,
                // `PeerPlatform.init(wireValue:)` tolerates a value this build has
                // never heard of, which is what a row written by a newer build
                // looks like.
                platform: PeerPlatform(wireValue: platformRaw),
                pairedAt: pairedAt
            )
            guard peer.deviceID.hex == deviceIDHex else { return nil }
            return peer
        }
    }

#endif
