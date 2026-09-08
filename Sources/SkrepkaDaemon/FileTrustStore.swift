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

    private struct StoredIdentity: Codable, Sendable {
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

    private let url: URL
    private let peers: any PairedDeviceStoring
    private var identity: DeviceCertificate?
    private let logger = Logger(label: "skrepka.trust")

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

    /// Creates the file with ``identityMode`` and writes it, refusing to
    /// overwrite one that already exists.
    ///
    /// `O_EXCL` is the race this cares about: two daemons started against one
    /// directory must not each generate an identity and have the second
    /// silently replace the first, because the first may already have been
    /// pinned by a peer. It also makes the "file appeared between the read
    /// above and this write" case fail loudly instead of destroying an identity.
    ///
    /// ## Why not a temporary file and a rename
    ///
    /// The usual atomic-write recipe would lose exactly the guarantee above:
    /// `rename(2)` replaces whatever is at the destination, so two daemons
    /// racing would each write their own identity and the loser's would win.
    /// So the create stays exclusive, and durability is bought the other way —
    /// write everything, `fsync`, then check the `close`.
    ///
    /// ## Why a failure unlinks, and only before `fsync` returns
    ///
    /// A truncated `device.key` is unreadable, and ``IdentityError/unreadable``
    /// is deliberately never repaired by generating a new one — so a
    /// half-written file would wedge `skrepkad` on every boot until a human
    /// moved it aside. Removing the partial file is what makes the next start
    /// a retry rather than the same failure for ever.
    ///
    /// **The boundary is `fsync`.** Once it has returned 0 the bytes are on
    /// the disk and the file is a whole identity whatever happens afterwards,
    /// so nothing past that point unlinks: removing it there would destroy a
    /// key a peer may already have pinned, and the next start would generate a
    /// fresh certificate and a fresh `SyncDeviceID` — silently un-pairing this
    /// machine from every peer it has. That is why the `close` sits outside the
    /// `do`, and why a `close` that fails is logged rather than thrown: the
    /// descriptor is gone either way and the identity is already durable.
    private func persist(_ identity: StoredIdentity) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryMode]
        )
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, Self.identityMode)
        }
        guard descriptor >= 0 else {
            throw IdentityError.cannotWrite(path: url.path, code: errno)
        }
        do {
            try Self.writeAll(try JSONEncoder().encode(identity), to: descriptor, at: url.path)
            // Before the close, so an identity a peer may pin in the next
            // second is on the disk and not only in the page cache.
            guard fsync(descriptor) == 0 else {
                throw IdentityError.cannotWrite(path: url.path, code: errno)
            }
        } catch {
            // The only path that unlinks, and the only path that closes here:
            // `close(2)` releases the descriptor even when it reports an
            // error, so closing it a second time would close whatever number
            // the kernel has since handed to a NIO or SQLite thread.
            _ = close(descriptor)
            _ = url.withUnsafeFileSystemRepresentation { path in path.map { unlink($0) } }
            throw error
        }
        if close(descriptor) != 0 {
            // Reported and not thrown: `fsync` has already returned, so the
            // identity is durable and the caller has nothing to retry.
            logger.warning(
                "the device key was written but its descriptor did not close cleanly",
                metadata: [
                    "path": .string(url.path),
                    "error": .string(String(cString: strerror(errno))),
                ]
            )
        }
    }

    /// `write(2)` until every byte has landed.
    ///
    /// One call can write fewer bytes than it was given, and the short write is
    /// how a full disk truncates a key rather than failing outright.
    private static func writeAll(_ data: Data, to descriptor: Int32, at path: String) throws {
        var written = 0
        while written < data.count {
            let count: Int = data.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress?.advanced(by: written), data.count - written)
            }
            guard count > 0 else {
                // EINTR is a signal arriving mid-write, not a failure; every
                // other negative return is, and a zero-byte write on a regular
                // file has nowhere left to put the bytes.
                if count < 0, errno == EINTR { continue }
                throw IdentityError.cannotWrite(path: path, code: count < 0 ? errno : ENOSPC)
            }
            written += count
        }
    }
}
