import Foundation
import NIOCore
import NIOPosix
import SkrepkaSync

/// A headless Skrepka peer: it speaks the whole protocol and **never touches a
/// pasteboard**.
///
/// That is the point of it. Two Mac desktop sessions would put Universal
/// Clipboard back in the test loop, which is the collision design §3 exists to
/// keep out, so the stand-in peer has no clipboard at all and advertises
/// `plat=linux` by default.
///
/// It depends on `SkrepkaSync` and not on `SkrepkaCore`, so it builds on Linux
/// and becomes the Phase 6 smoke-test binary for nothing.
///
/// The rest of this type is in `ProbePeer+Serving.swift` and
/// `ProbePeer+Links.swift`; Swift scopes `private` to one file, so what they
/// share is internal.
public actor ProbePeer {
    let options: ProbeOptions
    let store: ProbeStore
    let trust: ProbeTrustStore

    /// The store, for the command loop that shares it.
    ///
    /// `nonisolated` because it is an immutable `let` to an actor: reaching it
    /// costs no hop, and every method on it is isolated in its own right.
    public nonisolated var historyStore: ProbeStore { store }

    var runtime: SyncRuntime?
    var group: MultiThreadedEventLoopGroup?
    var syncServer: SyncServer?
    var pairingServer: SyncServer?
    var acceptTasks: [Task<Void, Never>] = []

    var links: [SyncDeviceID: PeerLink] = [:]
    var linkState: [SyncDeviceID: String] = [:]
    /// Addresses given by hand with `connect`, for a network with no mDNS —
    /// which is every Linux container this will run in before Phase 6.
    var manualAddresses: [SyncDeviceID: (host: String, port: UInt16)] = [:]

    /// A pairing waiting on `accept` or `reject`. Only reachable with
    /// `--confirm-pairing`.
    var pendingPairing: CheckedContinuation<Bool, Never>?

    #if canImport(Network) && canImport(dnssd)
        var discovery: BonjourDiscovery?
        var browseTask: Task<Void, Never>?
        var sighted: [SyncDeviceID: DiscoveredPeer] = [:]
    #endif

    public init(options: ProbeOptions) throws {
        self.options = options
        store = try ProbeStore(url: options.storeURL)
        trust = ProbeTrustStore(url: options.identityURL, peers: store)
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let certificate = try await trust.localIdentity()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        runtime = SyncRuntime(
            certificate: certificate,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: certificate.deviceID,
                    deviceName: options.name,
                    platform: options.platform,
                    protocolVersion: .current
                ),
                localCertificate: certificate
            ),
            trust: trust,
            store: store,
            group: group
        )
        try await startListeners()
        try await startDiscovery()
        await reconcileLinks()
        ProbeOutput.say(try await statusLines().joined(separator: "\n"))
    }

    public func stop() async {
        for task in acceptTasks {
            task.cancel()
        }
        acceptTasks = []
        for link in links.values {
            await link.stop()
        }
        links = [:]
        await stopDiscovery()
        await syncServer?.stop()
        await pairingServer?.stop()
        syncServer = nil
        pairingServer = nil
        // Callback form: the blocking one parks a cooperative-pool thread until
        // the loops drain, and draining them resumes continuations that need a
        // cooperative thread to run on.
        group?.shutdownGracefully { _ in }
        group = nil
        runtime = nil
    }

    // MARK: - What it is

    public func statusLines() async throws -> [String] {
        guard let runtime else { return ["not running"] }
        var lines = [
            "device   \(runtime.deviceID.hex)",
            "code     \(runtime.deviceID.fingerprint)",
            "name     \(options.name)  platform \(options.platform.rawValue)",
            "sync     port \(syncServer?.port ?? 0)",
        ]
        lines.append(
            pairingServer.map { "pairing  port \($0.port) — accepting new devices" }
                ?? "pairing  closed — start with --pair to accept new devices"
        )
        lines.append("store    \(options.storeURL.path)")
        let peers = await store.pairedPeers()
        lines.append(peers.isEmpty ? "peers    none" : "peers    \(peers.count) paired")
        return lines
    }
}

/// Everything the probe prints.
///
/// One place, so a run can be redirected and read later, and so nothing here
/// reaches for a logger that does not exist on both platforms.
public enum ProbeOutput {
    /// Written through `FileHandle` rather than `print`, and that is a
    /// portability requirement rather than a preference: flushing `print`'s
    /// buffer means touching `stdout`, which on Glibc is a mutable global and is
    /// therefore not concurrency-safe under Swift 6. `FileHandle` writes
    /// straight through, so an operator watching a redirected log sees each line
    /// as it happens without anything having to be flushed.
    public static func say(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    public static func fail(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
