// The paired-peer surface of the SwiftData store. Linux gets a separate SQLite
// conformance of HistoryStoring in Phase 4 storage work (D-9).
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import SwiftData
    import os

    /// The macOS backing store for `SkrepkaSync.TrustStore`.
    ///
    /// Every method here mirrors one of that protocol's requirements, minus the
    /// `async`: the app target's `KeychainTrustStore` keeps this device's private
    /// key in the Keychain, hops to the main actor for the peer list, and is the
    /// thing that actually conforms. `HistoryStore` does not, because the protocol
    /// lives in a target that must not import this one.
    extension HistoryStore {
        /// Every paired peer, oldest pairing first.
        public func pairedPeers() throws -> [PairedPeer] {
            let descriptor = FetchDescriptor<PairedDeviceRecord>(
                sortBy: [SortDescriptor(\.pairedAt, order: .forward)]
            )
            var result: [PairedPeer] = []
            for record in try context.fetch(descriptor) {
                guard let peer = PairedDeviceMapping.peer(from: record) else {
                    SkrepkaLog.store.error(
                        "Skipping a paired device whose stored identifier does not match its certificate."
                    )
                    continue
                }
                result.append(peer)
            }
            return result
        }

        public func pairedPeer(_ deviceID: SyncDeviceID) throws -> PairedPeer? {
            try pairedDeviceRecord(deviceID).flatMap(PairedDeviceMapping.peer(from:))
        }

        /// Inserts or replaces the record for `peer.deviceID`, leaving that peer's
        /// protocol high-water mark alone.
        public func savePairedPeer(_ peer: PairedPeer) throws {
            if let existing = try pairedDeviceRecord(peer.deviceID) {
                PairedDeviceMapping.update(existing, from: peer)
            } else {
                context.insert(PairedDeviceMapping.makeRecord(from: peer))
            }
            try context.save()
        }

        /// Forgets a peer and its high-water mark — a forgotten device is a
        /// stranger again, which is what makes re-pairing mean anything.
        ///
        /// Silent when it was not paired: unpairing twice is the same outcome as
        /// unpairing once.
        public func forgetPairedPeer(_ deviceID: SyncDeviceID) throws {
            guard let record = try pairedDeviceRecord(deviceID) else { return }
            context.delete(record)
            try context.save()
        }

        /// The highest protocol version this peer has ever advertised, or `nil` if
        /// it has never connected.
        ///
        /// Design §9's anti-downgrade rule compares against this: a peer that once
        /// spoke v2 and now advertises v1 is either an attacker stripping features
        /// or a rollback nobody asked for. Making that comparison is
        /// `PairingSession.verifyNoDowngrade(offered:remembered:)`; remembering the
        /// number is this store's job.
        public func highestProtocolVersion(for deviceID: SyncDeviceID) throws -> ProtocolVersion? {
            try pairedDeviceRecord(deviceID)?.highestProtocolSeen.map(ProtocolVersion.init(rawValue:))
        }

        /// Raises the mark when `version` is higher, and does nothing when it is
        /// not.
        ///
        /// **Never lowers it.** A store that lowered the mark would defeat the
        /// downgrade check silently — the handshake would keep comparing against a
        /// number an attacker had already talked it down to. Also does nothing for
        /// a peer that is not paired: there is no record to raise, and inventing
        /// one would create a trusted peer out of a connection attempt.
        public func recordProtocolVersion(
            _ version: ProtocolVersion,
            for deviceID: SyncDeviceID
        ) throws {
            guard let record = try pairedDeviceRecord(deviceID) else { return }
            if let seen = record.highestProtocolSeen, seen >= version.rawValue { return }
            record.highestProtocolSeen = version.rawValue
            try context.save()
        }

        private func pairedDeviceRecord(_ deviceID: SyncDeviceID) throws -> PairedDeviceRecord? {
            let hex = deviceID.hex
            var descriptor = FetchDescriptor<PairedDeviceRecord>(
                predicate: #Predicate { $0.deviceIDHex == hex }
            )
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }
    }

#endif
