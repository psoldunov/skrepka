import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

#if canImport(Glibc)
    import Glibc
#endif

/// The device identity file.
///
/// Two properties, and both are the kind that pass by accident and fail
/// silently: the file has to be created `0600` rather than tightened into it
/// afterwards, and the identity has to be the same one on every later read.
@Suite("File-backed trust store")
struct FileTrustStoreTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-trust-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func mode(of url: URL) -> mode_t? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return status.st_mode & 0o777
    }

    /// **At creation, not after.**
    ///
    /// The window between creating a world-readable file and `chmod`-ing it is
    /// small and real, and a private key is exactly the thing not to leave in
    /// it — which is why the write goes through `open(2)` with a mode rather
    /// than `Data.write(to:)`. This asserts the outcome; nothing here can prove
    /// the absence of the window, but a mode of 0600 on a file written any
    /// other way would need the umask to be doing it, which is not something to
    /// rely on.
    @Test("the key file is created 0600")
    func keyFileIsCreated0600() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/device.key", directoryHint: .notDirectory)

        let store = try SQLiteHistoryStore(location: nil)
        let trust = FileTrustStore(url: url, peers: store)
        _ = try await trust.localIdentity()

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(Self.mode(of: url) == 0o600)
        // The directory it made on the way is owner-only too. Debian's default
        // DIR_MODE=0755 on /home would otherwise leave it listable by every
        // other account on the machine.
        #expect(Self.mode(of: url.deletingLastPathComponent()) == 0o700)
    }

    @Test("the identity is stable across reads and across instances")
    func identityIsStable() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "device.key", directoryHint: .notDirectory)
        let store = try SQLiteHistoryStore(location: nil)

        let first = try await FileTrustStore(url: url, peers: store).localIdentity()
        let second = try await FileTrustStore(url: url, peers: store).localIdentity()
        // Regenerating changes `SyncDeviceID`, which is the hash of the
        // certificate's DER — so a new identity un-pairs the device from every
        // peer that pinned the old one.
        #expect(first.deviceID == second.deviceID)
        #expect(first.certificateDER == second.certificateDER)
    }

    /// **Never regenerates on a read failure.**
    ///
    /// A conformance that regenerated here would turn a transient read error —
    /// a disk hiccup, a half-written file, a truncated restore — into a silent
    /// re-pair of every peer. Reported instead, so the daemon refuses to start
    /// and the user can move the file aside deliberately.
    @Test("an unreadable key is reported, never replaced")
    func refusesToReplaceAnUnreadableKey() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "device.key", directoryHint: .notDirectory)
        try Data("not a device identity".utf8).write(to: url)
        let before = try Data(contentsOf: url)

        let trust = FileTrustStore(url: url, peers: try SQLiteHistoryStore(location: nil))
        await #expect(throws: FileTrustStore.IdentityError.self) {
            _ = try await trust.localIdentity()
        }
        // The bytes are untouched, which is the whole point: whatever was there
        // may be recoverable, and this build must not be what destroyed it.
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("the peer half is the store's, not a second copy")
    func delegatesPeersToTheStore() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteHistoryStore(location: nil)
        let trust = FileTrustStore(
            url: directory.appending(path: "device.key", directoryHint: .notDirectory),
            peers: store
        )
        let identity = try await trust.localIdentity()
        let peer = PairedPeer(
            certificateDER: identity.certificateDER,
            deviceName: "peer",
            platform: .macos,
            pairedAt: Date()
        )
        try await trust.savePairedPeer(peer)

        // Written through the trust store, readable from the store itself —
        // one table, two views of it.
        #expect(try await store.pairedPeers().count == 1)
        #expect(try await trust.pairedPeer(peer.deviceID)?.deviceName == "peer")

        try await trust.forgetPairedPeer(peer.deviceID)
        #expect(try await store.pairedPeers().isEmpty)
    }
}
