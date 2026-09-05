// periphery:ignore:all
//
// Nothing constructs this until Phase 3 wires the sync stack into
// AppCoordinator. It is the macOS `TrustStore` conformance, deliberately written
// ahead of its caller: `SkrepkaSync` cannot name it, because that target has to
// build on Linux, so the app target is the only place it can live — and an app
// target exports no public API for `retain_public` to keep. Deleting it to
// satisfy the scan would delete the reason `TrustStore` is a protocol at all.
//
// Remove this directive when AppCoordinator constructs one.

import Foundation
import Security
import SkrepkaSync

/// The macOS ``TrustStore``: the device's private key in the Keychain, its
/// paired peers wherever ``PairedDeviceStoring`` says.
///
/// `nonisolated` on the class rather than the app target's default main-actor
/// isolation, because the connection actors that read it are not on the main
/// actor and the `SecItem` functions are thread-safe.
///
/// **The legacy file keychain, deliberately.** `kSecAttrAccessible` is only
/// honoured on macOS when `kSecUseDataProtectionKeychain` or
/// `kSecAttrSynchronizable` is set — the header says so at `SecItem.h` — and
/// the data-protection keychain wants an application-identifier entitlement
/// that a Developer ID app outside the App Store does not carry. So this uses
/// the file keychain and gets the property that actually matters,
/// `kSecAttrSynchronizable: false`, which keeps a device's identity off iCloud
/// Keychain and therefore off every other Mac on the account. An identity that
/// synced would make two machines one device.
nonisolated final class KeychainTrustStore: TrustStore {
    /// Keychain service name. The bundle identifier, so an uninstall that
    /// clears the app's keychain items clears this one.
    static let service = "dev.soldunov.skrepka.sync"
    static let account = "device-identity"

    private let peers: any PairedDeviceStoring

    init(peers: any PairedDeviceStoring) {
        self.peers = peers
    }

    // MARK: - Identity

    func localIdentity() async throws -> DeviceCertificate {
        if let stored = try read() { return try stored.certificate() }

        let generated = try DeviceCertificate.generate()
        do {
            try add(StoredIdentity(generated))
            return generated
        } catch KeychainTrustStoreError.alreadyExists {
            // Another task got there first. Re-reading rather than overwriting
            // is the whole point: the identity that won is the one some peer
            // may already have pinned.
            guard let stored = try read() else {
                throw KeychainTrustStoreError.identityVanished
            }
            return try stored.certificate()
        }
    }

    // MARK: - Peers, delegated

    func pairedPeers() async throws -> [PairedPeer] { try await peers.pairedPeers() }

    func pairedPeer(_ deviceID: SyncDeviceID) async throws -> PairedPeer? {
        try await peers.pairedPeer(deviceID)
    }

    func savePairedPeer(_ peer: PairedPeer) async throws { try await peers.savePairedPeer(peer) }

    func forgetPairedPeer(_ deviceID: SyncDeviceID) async throws {
        try await peers.forgetPairedPeer(deviceID)
    }

    func highestProtocolVersion(for deviceID: SyncDeviceID) async throws -> ProtocolVersion? {
        try await peers.highestProtocolVersion(for: deviceID)
    }

    func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) async throws {
        try await peers.recordProtocolVersion(version, for: deviceID)
    }

    // MARK: - Keychain

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func read() throws -> StoredIdentity? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainTrustStoreError.unreadableItem }
            return try JSONDecoder().decode(StoredIdentity.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainTrustStoreError.keychain(status: status)
        }
    }

    private func add(_ identity: StoredIdentity) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = try JSONEncoder().encode(identity)

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess: return
        case errSecDuplicateItem: throw KeychainTrustStoreError.alreadyExists
        default: throw KeychainTrustStoreError.keychain(status: status)
        }
    }
}

/// The identity as it sits in one Keychain item.
///
/// One item rather than two so the certificate and the key that signs for it
/// can never be half-written: a certificate whose key is missing is an identity
/// that cannot complete a handshake and cannot be told from one that was never
/// created.
nonisolated private struct StoredIdentity: Codable {
    let certificateDER: Data
    let privateKeyPEM: String

    init(_ certificate: DeviceCertificate) {
        certificateDER = certificate.certificateDER
        privateKeyPEM = certificate.privateKeyPEM
    }

    func certificate() throws -> DeviceCertificate {
        try DeviceCertificate(certificateDER: certificateDER, privateKeyPEM: privateKeyPEM)
    }
}
