import Foundation
import Logging
import SkrepkaCore
import SkrepkaSync

#if canImport(Glibc)
    import Glibc
#endif

/// The daemon's ``SkrepkaSync/TrustStore``: its identity in a `0600` file, its
/// peers in the SQLite store beside it.
///
/// The third composition of the split `PairedDeviceStoring` exists to allow —
/// `KeychainTrustStore` on macOS and `ProbeTrustStore` in the probe are the
/// other two — and the one `TrustStore`'s own documentation describes:
///
/// > **Linux** keeps the key in a file at `$XDG_DATA_HOME/skrepka/device.key`,
/// > mode `0600`, **created with those permissions rather than `chmod`-ed into
/// > them afterwards**.
///
/// ## Why this is not `ProbeTrustStore` with a different store
///
/// It nearly is, and the duplication is deliberate rather than overlooked. The
/// probe's copy lives in `SkrepkaProbe`, which must not depend on
/// `SkrepkaCore` — that is what keeps it building on Linux ahead of the port
/// and what guarantees it can never reach a clipboard. Sharing this type would
/// mean moving it into `SkrepkaSync`, which would put a `TrustStore`
/// conformance with a hard-coded file layout into the target that exists
/// precisely to hold no platform decisions. Forty lines twice is the cheaper of
/// the two.
public actor FileTrustStore: TrustStore {
    /// Permissions the identity file is created with: owner read and write, and
    /// nothing else.
    static let identityMode: mode_t = 0o600

    /// Permissions the directory holding it is created with.
    ///
    /// `0700`, matching what `SQLiteHistoryStore.prepareOnDisk` gives the
    /// database in the same directory. Debian's default `DIR_MODE=0755` on
    /// `/home` would otherwise leave `~/.local/share/skrepka` listable by every
    /// other account on the machine.
    static let directoryMode: NSNumber = 0o700

    struct StoredIdentity: Codable, Sendable {
        let certificateDER: Data
        let privateKeyPEM: String
    }

    /// What the store refuses to do rather than do unsafely.
    public enum IdentityError: Error, Sendable, CustomStringConvertible {
        /// The key file could not be created with owner-only permissions.
        case cannotWrite(path: String, code: Int32)
        /// The file exists and does not hold an identity this build can read.
        ///
        /// **Never repaired by generating a new one.** `SyncDeviceID` is the
        /// hash of the certificate's bytes, so a fresh certificate is a fresh
        /// device and every peer that pinned the old one has to be paired
        /// again. A transient read error must not become a silent re-pair, so
        /// this is reported and the daemon refuses to start.
        case unreadable(path: String, reason: String)

        public var description: String {
            switch self {
            case .cannotWrite(let path, let code):
                "could not create the device key at \(path): \(String(cString: strerror(code)))"
            case .unreadable(let path, let reason):
                """
                the device key at \(path) could not be read: \(reason). \
                Skrepka will not generate a new one, because that would change this \
                device's identity and un-pair it from every peer. Move the file aside \
                to start over deliberately.
                """
            }
        }
    }

    let url: URL
    private let peers: any PairedDeviceStoring
    private var identity: DeviceCertificate?
    let logger = Logger(label: "skrepka.trust")

    /// - Parameters:
    ///   - url: where the key lives. `SessionPaths.deviceKeyURL()` in
    ///     production; a temporary directory under test.
    ///   - peers: the SQLite store, which already conforms.
    public init(url: URL, peers: any PairedDeviceStoring) {
        self.url = url
        self.peers = peers
    }

    // MARK: - Identity

    /// The stored identity, generating and persisting one the first time.
    public func localIdentity() throws -> DeviceCertificate {
        if let identity { return identity }
        if let stored = try read() {
            let certificate = try DeviceCertificate(
                certificateDER: stored.certificateDER,
                privateKeyPEM: stored.privateKeyPEM
            )
            identity = certificate
            return certificate
        }
        let generated = try DeviceCertificate.generate()
        try persist(
            StoredIdentity(
                certificateDER: generated.certificateDER,
                privateKeyPEM: generated.privateKeyPEM
            ))
        identity = generated
        return generated
    }

    // MARK: - Peers, delegated

    public func pairedPeers() async throws -> [PairedPeer] { try await peers.pairedPeers() }

    public func pairedPeer(_ deviceID: SyncDeviceID) async throws -> PairedPeer? {
        try await peers.pairedPeer(deviceID)
    }

    public func savePairedPeer(_ peer: PairedPeer) async throws {
        try await peers.savePairedPeer(peer)
    }

    public func forgetPairedPeer(_ deviceID: SyncDeviceID) async throws {
        try await peers.forgetPairedPeer(deviceID)
    }

    public func highestProtocolVersion(for deviceID: SyncDeviceID) async throws -> ProtocolVersion? {
        try await peers.highestProtocolVersion(for: deviceID)
    }

    public func recordProtocolVersion(
        _ version: ProtocolVersion,
        for deviceID: SyncDeviceID
    ) async throws {
        try await peers.recordProtocolVersion(version, for: deviceID)
    }

    public func livePushChoice(for deviceID: SyncDeviceID) async throws -> LivePushChoice {
        try await peers.livePushChoice(for: deviceID)
    }

    public func setLivePushChoice(
        _ choice: LivePushChoice,
        for deviceID: SyncDeviceID
    ) async throws {
        try await peers.setLivePushChoice(choice, for: deviceID)
    }

    // MARK: - The file

    private func read() throws -> StoredIdentity? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(StoredIdentity.self, from: Data(contentsOf: url))
        } catch {
            throw IdentityError.unreadable(path: url.path, reason: String(describing: error))
        }
    }
}
