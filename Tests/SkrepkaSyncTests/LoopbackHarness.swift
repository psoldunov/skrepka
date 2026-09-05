import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import SkrepkaSync

/// Two devices, one event loop group, and a store on each side.
///
/// Certificate generation is the expensive part of every loopback test — a
/// fresh P-256 key and a signature per identity — so the harness makes exactly
/// two and hands the same pair to every connection in a test.
struct LoopbackHarness {
    static let host = "127.0.0.1"
    static let contentHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
    static let representation = RepresentationKey(canonical: "text/plain;charset=utf-8")

    let group: MultiThreadedEventLoopGroup
    let serverIdentity: DeviceCertificate
    let clientIdentity: DeviceCertificate
    let serverTrust: InMemoryTrustStore
    let clientTrust: InMemoryTrustStore
    // Only the server side holds a store. The client's would be the empty one a
    // real initiator merges into, and no test has needed it yet — a
    // `FakeHistoryStore()` nothing reads is a claim about the harness that is not
    // true, so it is added when a test wants it.
    let serverStore: FakeHistoryStore
    let now: Date

    init() async throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        serverIdentity = try DeviceCertificate.generate()
        clientIdentity = try DeviceCertificate.generate()
        serverTrust = InMemoryTrustStore(identity: serverIdentity)
        clientTrust = InMemoryTrustStore(identity: clientIdentity)
        now = Date()

        serverStore = FakeHistoryStore(
            items: [
                SyncClipMeta(
                    contentHash: Self.contentHash,
                    kind: "text",
                    preview: "the quick brown fox",
                    createdAt: now,
                    isPinned: LWWRegister(value: false, timestamp: now, deviceID: serverIdentity.deviceID),
                    originDeviceID: serverIdentity.deviceID,
                    representations: [
                        RepresentationDescriptor(key: Self.representation, byteCount: Self.payload.count)
                    ]
                )
            ],
            payloads: [Self.contentHash: [Self.representation: Self.payload]]
        )
    }

    /// Polls `read` until it answers, or gives up.
    ///
    /// The server refuses a client *after* TLS 1.3 has let that client finish,
    /// so the refusal lands a moment after `connect` returns and there is no
    /// event to await. Bounded rather than open-ended: a test that hangs is
    /// worse than one that fails.
    func eventually<Value>(
        within seconds: Double = 5,
        _ read: @Sendable () async -> Value?
    ) async throws -> Value {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if let value = await read() { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HarnessTimeout()
    }

    /// Tears the group down without waiting for it.
    ///
    /// **`syncShutdownGracefully()` must never be called here, and the reason is
    /// a deadlock rather than a preference.** Every caller runs this from a
    /// `defer` inside an `async` test, so it executes on a cooperative-pool
    /// thread. That call blocks on a semaphore until the group's loops drain,
    /// and draining them resumes continuations that need a cooperative thread to
    /// run on. Under `swift test --parallel` enough suites reach their `defer`
    /// together to occupy every thread in the pool, and none of them can be
    /// resumed by the threads they are all waiting on. The run wedges at roughly
    /// two thirds of the suite with every thread parked in
    /// `semaphore_wait_trap` — reproduced here, confirmed with `sample`.
    ///
    /// So the callback form, which returns immediately and lets the group finish
    /// on its own threads. A `defer` cannot `await`, and `Task { }` would not
    /// help: the shutdown has to not block, not merely be moved.
    ///
    /// The cost is that a group which fails to shut down is no longer reported.
    /// That check never worked anyway — it was `try?` before — and a leaked
    /// group in a process about to exit is a far smaller problem than a suite
    /// that hangs half the time. ``shutdownAndWait()`` is the version that
    /// checks, for a test that wants to assert on teardown.
    func shutdown() {
        group.shutdownGracefully { _ in }
    }

    // A `shutdownAndWait()` that awaits `group.shutdownGracefully()` and reports
    // a dirty teardown belongs here, and is deliberately absent: every call site
    // is a `defer`, which cannot `await`, so it had no caller and the dead-code
    // scan was right to say so. Add it with its first real user — a test that
    // asserts on teardown — rather than ahead of one.

    func startServer(identity: DeviceCertificate, policy: PinPolicy) async throws -> SyncServer {
        try await SyncServer.start(identity: identity, policy: policy, host: Self.host, group: group)
    }

    /// A server and a client already connected to it, both ends in hand.
    func connectedPair(policy: PinPolicy) async throws -> ConnectedPair {
        try await connectedPair(serverPolicy: policy, clientPolicy: policy)
    }

    /// The same, where the two ends pin differently — which is the ordinary
    /// case once pairing has happened, since each end pins the other's
    /// certificate rather than its own.
    func connectedPair(serverPolicy: PinPolicy, clientPolicy: PinPolicy) async throws -> ConnectedPair {
        let server = try await startServer(identity: serverIdentity, policy: serverPolicy)
        async let accepted = server.nextConnection()
        let client = try await SyncClient.connect(
            host: Self.host,
            port: server.port,
            identity: clientIdentity,
            policy: clientPolicy,
            group: group
        )
        guard let serverSide = await accepted else {
            await server.stop()
            throw SyncTLSError.handshakeIncomplete
        }
        return ConnectedPair(server: server, serverSide: serverSide, client: client)
    }

    func responder(for connection: SyncConnection) -> SyncResponder {
        SyncResponder(
            connection: connection,
            session: PairingSession(
                localIdentity: identity(serverIdentity, name: "server", platform: .macos),
                localCertificate: serverIdentity
            ),
            trust: serverTrust,
            store: serverStore,
            confirmPairing: { _ in true },
            now: { now }
        )
    }

    /// An initiator on the client side of `connection`.
    ///
    /// `expecting` is passed through rather than defaulted so a test has to say
    /// which peer it meant to dial — nil for first contact, where nothing is
    /// pinned and there is nothing to expect yet.
    func initiator(
        for connection: SyncConnection,
        expecting expectedPeerDeviceID: SyncDeviceID? = nil
    ) throws -> SyncInitiator {
        try SyncInitiator(
            connection: connection,
            session: PairingSession(
                localIdentity: identity(clientIdentity, name: "client", platform: .linux),
                localCertificate: clientIdentity
            ),
            trust: clientTrust,
            expecting: expectedPeerDeviceID
        )
    }

    private func identity(
        _ certificate: DeviceCertificate,
        name: String,
        platform: PeerPlatform
    ) -> PeerIdentity {
        PeerIdentity(
            deviceID: certificate.deviceID,
            deviceName: name,
            platform: platform,
            protocolVersion: .current
        )
    }
}

/// Both ends of one loopback connection, plus the server that made it.
struct ConnectedPair {
    let server: SyncServer
    let serverSide: SyncConnection
    let client: SyncConnection

    func close() async {
        await client.close()
        await serverSide.close()
        await server.stop()
    }
}

/// Raised when ``LoopbackHarness/eventually(within:_:)`` gives up.
struct HarnessTimeout: Error {}
