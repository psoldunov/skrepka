import Foundation

/// One outbound connection to one paired peer, kept up for as long as sync is
/// running.
///
/// **This is the connection this device pushes over.** A device only ever sends
/// unsolicited messages on the connection it dialled, where it holds
/// `SyncInitiator`'s role — see that type for why that removes the need for a
/// correlation identifier on the wire. The other direction is the peer's own
/// link, which arrives at this device's listener and is answered by a
/// `SyncResponder`. So a pair of machines holds two connections, one owned by
/// each, and neither has to interleave two roles on one stream.
///
/// An actor because it owns a connection, a retry loop and a cursor that a live
/// push and the sync loop both touch. Per the repo's conventions, declarations
/// inside an actor are exempt from the app target's default main-actor
/// isolation, so none of this runs on the main thread.
public actor PeerLink {
    /// How often a connected link re-exchanges indexes.
    ///
    /// Comfortably inside `SyncChannelWiring.pinnedReadTimeout` (120 s), which
    /// is what stops an idle-but-healthy link being closed as dead: each
    /// exchange is a read at both ends.
    ///
    /// It is also how long a pin or a delete takes to reach the peer in the
    /// worst case. Live push covers the copy-and-paste path, which is the one a
    /// user is watching; everything else is allowed half a minute.
    public static let resyncInterval: Duration = .seconds(30)

    /// How often a waiting link looks at whether it has been asked to sync now.
    ///
    /// Polling rather than a continuation the wait races against, and the reason
    /// is proportion: this is one wakeup per second per paired peer against a
    /// clipboard watcher that already polls five times a second, and the
    /// alternative is a hand-rolled awaitable gate — a `CheckedContinuation`
    /// stored on an actor, resumed from another, and dropped correctly on
    /// cancellation. That is the shape with a `SWIFT TASK CONTINUATION MISUSE`
    /// in it, and it would be buying a second of latency.
    static let resyncPollInterval: Duration = .seconds(1)

    /// Waits between reconnection attempts, by consecutive failure count.
    ///
    /// A laptop that closes its lid, a peer that reboots and a peer that has
    /// genuinely gone all look the same from here, so the delay grows and then
    /// stops growing: a machine that comes back after an hour should be picked
    /// up within a minute, not within an hour.
    public static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(60)]

    /// Bytes one sync round will spend fetching payloads before returning to
    /// the loop.
    ///
    /// A first sync against a full history would otherwise sit inside one round
    /// for minutes. Nothing is lost by stopping early: the next round re-offers
    /// the same index, and what is still missing bytes is still missing them, so
    /// the fetch resumes where the budget ran out. One maximum-sized item is the
    /// unit, because that is the largest single fetch that cannot be split.
    public static let payloadBudgetPerSync = SyncLimits.maximumPayloadBytes

    /// How long a push handed to ``fetchPushed(_:)`` stays worth delivering.
    ///
    /// The bytes are fetched on the next exchange, and a link that is down
    /// reaches its next exchange whenever it reconnects — possibly an hour
    /// later, when putting that item on the clipboard would replace whatever
    /// the user has there with something they copied on another machine long
    /// ago. Past this the item is still fetched and stored like any other; it
    /// is only no longer handed to ``onPushFetched``.
    public static let pushFetchWindow: Duration = .seconds(60)

    public let peerDeviceID: SyncDeviceID

    private let runtime: SyncRuntime
    /// Resolved fresh on every attempt rather than once: a peer's address
    /// outlives neither sleep nor a network change, and `PeerDiscovery.resolve`
    /// says to call it immediately before connecting.
    private let resolve: @Sendable () async throws -> ResolvedPeer
    private let report: @Sendable (SyncDeviceID, PeerLinkEvent) async -> Void
    /// Turns a failure into the sentence a report carries.
    ///
    /// Injected because this target builds on Linux and owns no user-facing
    /// copy, while the thing that displays a report is a settings pane on
    /// macOS. The default is the same `CustomStringConvertible` description that
    /// goes to a log, which is the right answer for a headless peer.
    private let describeFailure: @Sendable (any Error) -> String
    /// Told about a pushed item once its bytes have been fetched and stored.
    private let onPushFetched: LivePushSink

    private var task: Task<Void, Never>?
    private var connection: SyncConnection?
    private var initiator: SyncInitiator?
    private var consecutiveFailures = 0
    /// Set by ``resync()``, cleared by the wait that acts on it.
    private var isResyncRequested = false
    /// The push ``fetchPushed(_:)`` was last handed, until an exchange takes it.
    private var pendingPush: PendingPush?

    private struct PendingPush: Sendable {
        let contentHash: String
        let deadline: ContinuousClock.Instant
    }

    /// - Parameter onPushFetched: told about an item handed to
    ///   ``fetchPushed(_:)`` once its bytes have been fetched and stored,
    ///   within ``pushFetchWindow``. It receives every representation the
    ///   fetch brought. Whether to put it on the clipboard is the caller's —
    ///   see ``LivePushGate/claimFetched(_:at:)``. Defaults to doing nothing.
    public init(
        peerDeviceID: SyncDeviceID,
        runtime: SyncRuntime,
        resolve: @escaping @Sendable () async throws -> ResolvedPeer,
        report: @escaping @Sendable (SyncDeviceID, PeerLinkEvent) async -> Void,
        describeFailure: @escaping @Sendable (any Error) -> String = { String(describing: $0) },
        onPushFetched: @escaping LivePushSink = { _, _ in }
    ) {
        self.peerDeviceID = peerDeviceID
        self.runtime = runtime
        self.resolve = resolve
        self.report = report
        self.describeFailure = describeFailure
        self.onPushFetched = onPushFetched
    }

    // MARK: - Lifetime

    /// Starts the connect-sync-retry loop. Calling it again while it is running
    /// does nothing, so a discovery event that re-announces a peer costs
    /// nothing.
    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() async {
        task?.cancel()
        task = nil
        await closeConnection()
    }

    /// Asks for an index exchange now rather than at the end of the current
    /// wait.
    ///
    /// What "force a re-sync" means. A pin and a deletion reach a peer on the
    /// next exchange, which is up to ``resyncInterval`` away — fine to wait for
    /// in ordinary use, and no use at all to somebody checking that a deletion
    /// stuck.
    ///
    /// Does nothing to a link that is not connected: there is nothing to hurry,
    /// and the reconnect loop is already trying.
    public func resync() {
        isResyncRequested = true
    }

    // MARK: - Live push

    /// Hands the peer what was just copied here, if the connection is up.
    ///
    /// Silent when it is not. A live push is a convenience over a history sync
    /// that will carry the same item within ``resyncInterval``, so a peer that
    /// is asleep costs the user a handoff rather than the clipping.
    ///
    /// Deliberately not serialised against the sync loop. `SyncInitiator` is an
    /// actor, so two frames cannot interleave inside one message, and a
    /// `livePush` written between an initiator's request and its reply is just
    /// the next message the peer's responder reads. Waiting for a full index
    /// exchange to finish before pushing is exactly the delay design §11 asks to
    /// avoid.
    public func push(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async {
        guard let initiator else { return }
        do {
            try await initiator.push(meta, payloads: payloads)
            await report(peerDeviceID, .pushed)
        } catch {
            // A write that failed is a connection that has gone, so it is
            // reported as one. The loop reaches the same conclusion on its next
            // exchange; reporting twice costs nothing, because the row it lands
            // in holds a state rather than a history.
            await report(peerDeviceID, .failed(reason: describeFailure(error)))
        }
    }

    /// Fetches the bytes of an item the peer pushed without them, now rather
    /// than on the exchange ``resyncInterval`` away.
    ///
    /// Asks for an exchange — the peer only serves bytes of what it offered on
    /// this connection, so the fetch has to follow a fresh index — and puts the
    /// item first in its fetch order. Once the bytes are stored they go to
    /// `onPushFetched`, provided that happens within ``pushFetchWindow``.
    ///
    /// A second call replaces the first: only the newest push is worth putting
    /// on a clipboard. The older one is still fetched, in its turn.
    public func fetchPushed(_ meta: SyncClipMeta) {
        pendingPush = PendingPush(
            contentHash: meta.contentHash,
            deadline: ContinuousClock.now.advanced(by: Self.pushFetchWindow)
        )
        isResyncRequested = true
    }

    // MARK: - The loop

    private func run() async {
        while !Task.isCancelled {
            do {
                try await connectAndSync()
                consecutiveFailures = 0
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                await report(peerDeviceID, .failed(reason: describeFailure(error)))
            }
            await closeConnection()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: retryDelay())
        }
    }

    private func retryDelay() -> Duration {
        let index = min(max(consecutiveFailures - 1, 0), Self.retryDelays.count - 1)
        return Self.retryDelays[index]
    }

    /// Dials, handshakes, and then exchanges indexes until the connection ends.
    private func connectAndSync() async throws {
        await report(peerDeviceID, .connecting)
        let resolved = try await resolve()
        // Pinned to this one peer rather than to the whole paired set: the set
        // would let an attacker who can spoof Bonjour redirect a connection
        // meant for the desktop to the laptop, and every layer below would be
        // satisfied. `SyncInitiator.init(expecting:)` refuses the same thing one
        // layer up; both, because either alone leaves a window.
        let connection = try await SyncClient.connect(
            host: resolved.host,
            port: Int(resolved.port),
            identity: runtime.certificate,
            policy: .pinned([peerDeviceID]),
            group: runtime.group
        )
        self.connection = connection

        let initiator = try SyncInitiator(
            connection: connection,
            session: runtime.pairing,
            trust: runtime.trust,
            expecting: peerDeviceID,
            fileSync: runtime.fileSync
        )
        self.initiator = initiator

        let peer = try await initiator.handshake()
        await report(peerDeviceID, .connected(name: peer.deviceName, platform: peer.platform))

        while !Task.isCancelled {
            isResyncRequested = false
            let learned = try await exchange(over: initiator).run()
            await report(peerDeviceID, .synced(learned: learned, at: Date()))
            try await waitForNextExchange()
        }
    }

    /// One exchange, carrying the pending push — if one is still worth
    /// delivering — as the item to fetch first and the one to hand on.
    private func exchange(over initiator: SyncInitiator) -> SyncExchange {
        let pending = pendingPush.flatMap { $0.deadline > ContinuousClock.now ? $0 : nil }
        pendingPush = nil
        guard let pending else { return SyncExchange(runtime: runtime, initiator: initiator) }
        let deliver = onPushFetched
        let handOn: LivePushSink = { meta, payloads in
            guard meta.contentHash == pending.contentHash, ContinuousClock.now < pending.deadline else {
                return
            }
            await deliver(meta, payloads)
        }
        return SyncExchange(
            runtime: runtime, initiator: initiator, priority: pending.contentHash, onFetched: handOn)
    }

    /// Waits out ``resyncInterval``, or returns early once ``resync()`` has been
    /// called.
    ///
    /// Cancellation propagates from `Task.sleep`, which is what stops a link
    /// spending up to half a minute after `stop()` deciding to notice.
    private func waitForNextExchange() async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.resyncInterval)
        while ContinuousClock.now < deadline {
            if isResyncRequested { return }
            try await Task.sleep(for: Self.resyncPollInterval)
        }
    }

    private func closeConnection() async {
        initiator = nil
        if let connection {
            await connection.close()
        }
        connection = nil
    }
}
