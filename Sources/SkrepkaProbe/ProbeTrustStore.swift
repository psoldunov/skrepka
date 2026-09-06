import Foundation
import SkrepkaSync

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The probe's ``TrustStore``: its identity in a `0600` file, its peers in the
/// ``ProbeStore`` beside it.
///
/// Composed the same way `KeychainTrustStore` is — one object for the private
/// key, another for the peer records — because that is the split
/// `PairedDeviceStoring` exists to allow, and a second composition of it is
/// what shows the split was real.
///
/// **The key file is created with its permissions rather than `chmod`-ed into
/// them**, which is what `TrustStore` asks of the Linux conformance and the
/// reason this is written with `open(2)` rather than `Data.write(to:)`. The
/// window between creating a world-readable file and tightening it is small and
/// real, and a private key is exactly the thing not to leave in it.
public actor ProbeTrustStore: TrustStore {
    /// Permissions the identity file is created with: owner read and write, and
    /// nothing else.
    static let identityMode: mode_t = 0o600

    private struct StoredIdentity: Codable, Sendable {
        let certificateDER: Data
        let privateKeyPEM: String
    }

    private let url: URL
    private let peers: ProbeStore
    private var identity: DeviceCertificate?

    public init(url: URL, peers: ProbeStore) {
        self.url = url
        self.peers = peers
    }

    // MARK: - Identity

    /// The stored identity, generating and persisting one the first time.
    ///
    /// Never regenerates on a read failure. `SyncDeviceID` is the hash of the
    /// certificate's bytes, so a new certificate is a new device and every peer
    /// that pinned the old one has to be paired again — a transient read error
    /// must not become a silent re-pair.
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
        try write(
            StoredIdentity(
                certificateDER: generated.certificateDER,
                privateKeyPEM: generated.privateKeyPEM
            ))
        identity = generated
        return generated
    }

    // MARK: - Peers, delegated

    public func pairedPeers() async -> [PairedPeer] { await peers.pairedPeers() }

    public func pairedPeer(_ deviceID: SyncDeviceID) async -> PairedPeer? {
        await peers.pairedPeer(deviceID)
    }

    public func savePairedPeer(_ peer: PairedPeer) async throws {
        try await peers.savePairedPeer(peer)
    }

    public func forgetPairedPeer(_ deviceID: SyncDeviceID) async throws {
        try await peers.forgetPairedPeer(deviceID)
    }

    public func highestProtocolVersion(for deviceID: SyncDeviceID) async -> ProtocolVersion? {
        await peers.highestProtocolVersion(for: deviceID)
    }

    public func recordProtocolVersion(
        _ version: ProtocolVersion,
        for deviceID: SyncDeviceID
    ) async throws {
        try await peers.recordProtocolVersion(version, for: deviceID)
    }

    public func livePushChoice(for deviceID: SyncDeviceID) async -> LivePushChoice {
        await peers.livePushChoice(for: deviceID)
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
        return try JSONDecoder().decode(StoredIdentity.self, from: try Data(contentsOf: url))
    }

    /// Creates the file with ``identityMode`` and writes it, refusing to
    /// overwrite one that already exists.
    ///
    /// `O_EXCL` is the race this cares about: two probes started against one
    /// directory must not each generate an identity and have the second silently
    /// replace the first, because the first may already have been pinned by a
    /// peer.
    private func write(_ identity: StoredIdentity) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_CREAT | O_EXCL, Self.identityMode)
        }
        guard descriptor >= 0 else {
            throw ProbeError.couldNotWriteIdentity(path: url.path, code: errno)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: try JSONEncoder().encode(identity))
    }
}

/// What the probe fails with, in the two places a message is worth more than a
/// POSIX number on its own.
public enum ProbeError: Error, CustomStringConvertible {
    case couldNotWriteIdentity(path: String, code: Int32)
    case unknownCommand(String)
    case missingArgument(command: String, expected: String)

    public var description: String {
        switch self {
        case .couldNotWriteIdentity(let path, let code):
            "could not create \(path): \(String(cString: strerror(code)))"
        case .unknownCommand(let name):
            "unknown command '\(name)'"
        case .missingArgument(let command, let expected):
            "'\(command)' needs \(expected)"
        }
    }
}
