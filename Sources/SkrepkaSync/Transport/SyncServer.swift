import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// Listens for peers.
///
/// A child channel becomes a ``SyncConnection`` only after its handshake has
/// completed and its certificate has been pinned, so
/// ``nextConnection()`` never yields a peer this device has not verified. A
/// child that fails either step is closed and its reason is kept in
/// ``refusals()`` rather than dropped — an operator debugging a pairing that
/// will not take needs to see "unpinned certificate" somewhere.
///
/// Three of the four things it does are about the peers it turns *away*, and
/// they are here rather than in the pipeline because they are properties of the
/// listener rather than of any one connection: a ceiling on children in flight,
/// a deadline on each handshake, and a ceiling on the refusal log. Without them
/// an attacker who can open TCP connections owns every file descriptor the
/// process has, and the user's own laptop is the one that stops being accepted.
public actor SyncServer {
    /// Longest a child may sit between being accepted and completing its TLS
    /// handshake.
    ///
    /// `swift-nio-ssl` 2.37.4 supplies none of its own — it exposes
    /// `shutdownTimeout` and nothing resembling a handshake deadline — so
    /// without this a peer that completes TCP and then says nothing holds a
    /// descriptor, a pipeline, a BoringSSL connection object and a suspended
    /// `Task` for the life of the process. Ten seconds is far longer than TLS
    /// 1.3 over a LAN needs and short enough that holding descriptors costs an
    /// attacker a steady stream of new connections rather than one burst.
    static let handshakeTimeout = TimeAmount.seconds(10)

    /// Children allowed in flight at once, verified or not.
    ///
    /// The real deployment is a handful of the user's own machines, so a ceiling
    /// this far above that will never be reached by legitimate use, and reaching
    /// it is itself the signal. Refusing the newest is deliberate: the ones
    /// already inside are the ones with a chance of being the user's.
    public static let maximumConcurrentChildren = 32

    /// Refusals kept before the oldest are dropped.
    ///
    /// The log is filled entirely by remote parties, so an unbounded one is a
    /// leak with a network interface in front of it. Recent refusals are what an
    /// operator is reading anyway.
    static let refusalLogLimit = 32

    /// The port actually bound, which is what a caller that passed `0` needs.
    public nonisolated let port: Int

    /// The three pieces of state a child connection touches, which outlive any
    /// one of them and belong to the listener.
    ///
    /// One value rather than three parameters because they are never threaded
    /// anywhere separately: `start` builds all three, the child initialiser
    /// needs all three, and the actor holds all three. Passing them singly
    /// pushed `initialise` past SwiftLint's parameter ceiling, which was the
    /// rule noticing the same thing.
    struct ListenerState: Sendable {
        let accepted: Mailbox<SyncConnection>
        let refusalLog: NIOLockedValueBox<[String]>
        let children: NIOLockedValueBox<[ObjectIdentifier: any Channel]>
    }

    private let channel: any Channel
    private let state: ListenerState

    // `nonisolated` because the stored `let`s these replaced were: `state` is an
    // immutable `Sendable` value, and `refusals()` reads the log from outside the
    // actor.
    private nonisolated var accepted: Mailbox<SyncConnection> { state.accepted }
    private nonisolated var refusalLog: NIOLockedValueBox<[String]> { state.refusalLog }
    private nonisolated var children: NIOLockedValueBox<[ObjectIdentifier: any Channel]> {
        state.children
    }

    private init(channel: any Channel, state: ListenerState) {
        self.channel = channel
        port = channel.localAddress?.port ?? 0
        self.state = state
    }

    public static func start(
        identity: DeviceCertificate,
        policy: PinPolicy,
        host: String = "127.0.0.1",
        port: Int = 0,
        group: any EventLoopGroup
    ) async throws -> SyncServer {
        let context = try SyncTLS.context(for: SyncTLS.serverConfiguration(identity: identity))
        // Sized to the child ceiling on purpose: a verified peer must never be
        // dropped for want of queue space before ``maximumConcurrentChildren``
        // has already refused it at the door.
        let state = ListenerState(
            accepted: Mailbox<SyncConnection>(capacity: maximumConcurrentChildren),
            refusalLog: NIOLockedValueBox<[String]>([]),
            children: NIOLockedValueBox<[ObjectIdentifier: any Channel]>([:])
        )

        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                Self.initialise(child: child, context: context, policy: policy, state: state)
            }
            .bind(host: host, port: port)
            .get()

        return SyncServer(channel: channel, state: state)
    }

    /// The next verified peer, or nil once the server has stopped.
    public func nextConnection() async -> SyncConnection? {
        await accepted.next()
    }

    /// Why child connections were turned away, most recent
    /// ``refusalLogLimit`` first to arrive and last to leave.
    public nonisolated func refusals() -> [String] {
        refusalLog.withLockedValue { $0 }
    }

    /// Stops listening, and takes every connection this server made with it.
    ///
    /// Closing the children is the part that is easy to leave out and expensive
    /// to leave out. A ``SyncConnection`` still queued in the accept mailbox was
    /// never handed to anyone, so nobody else *can* close it; one already handed
    /// out belongs to a caller with no reason to know the server went. Both are
    /// live sockets to unverified or half-verified peers on channels this object
    /// opened, and "stopped" that leaves them open is not stopped.
    public func stop() async {
        accepted.finish()
        let live = children.withLockedValue { live -> [any Channel] in
            let channels = Array(live.values)
            live.removeAll()
            return channels
        }
        for child in live {
            // Already closed is the state being asked for, and a child that
            // closed itself a moment ago is the ordinary case here.
            try? await child.close().get()
        }
        // The same, for the listening channel.
        try? await channel.close().get()
    }

    private static func initialise(
        child: any Channel,
        context: NIOSSLContext,
        policy: PinPolicy,
        state: ListenerState
    ) -> EventLoopFuture<Void> {
        let (accepted, refusalLog) = (state.accepted, state.refusalLog)
        guard admit(child, to: state.children) else {
            record("refused: \(maximumConcurrentChildren) connections already in flight", in: refusalLog)
            child.close(promise: nil)
            return child.eventLoop.makeSucceededVoidFuture()
        }

        let wiring = SyncChannelWiring(policy: policy)
        let handshake = child.eventLoop.makePromise(of: Void.self)
        do {
            let tls = NIOSSLServerHandler(
                context: context,
                customVerificationCallback: SyncTLS.verificationCallback(
                    policy: policy,
                    verification: wiring.verification
                )
            )
            try child.pipeline.syncOperations.addHandlers(
                [tls, TLSHandshakeGate(promise: handshake)] + wiring.inboundHandlers()
            )
        } catch {
            handshake.fail(error)
            return child.eventLoop.makeFailedFuture(error)
        }
        scheduleHandshakeDeadline(for: child, promise: handshake)

        Task {
            do {
                accepted.deliver(
                    try await wiring.connection(channel: child, handshake: handshake.futureResult)
                )
            } catch {
                record(String(describing: error), in: refusalLog)
            }
        }
        return child.eventLoop.makeSucceededVoidFuture()
    }

    /// Registers a child if there is room for one, and arranges its removal.
    ///
    /// Keyed by identity rather than counted, because the same bookkeeping has
    /// to answer both "how many are in flight" and "which channels does
    /// ``stop()`` have to close", and two structures that can disagree about
    /// that is one structure and one leak.
    private static func admit(
        _ child: any Channel,
        to children: NIOLockedValueBox<[ObjectIdentifier: any Channel]>
    ) -> Bool {
        let key = ObjectIdentifier(child)
        let admitted = children.withLockedValue { live -> Bool in
            guard live.count < maximumConcurrentChildren else { return false }
            live[key] = child
            return true
        }
        guard admitted else { return false }
        child.closeFuture.whenComplete { _ in
            children.withLockedValue { $0[key] = nil }
        }
        return true
    }

    /// Gives one child's handshake a deadline.
    ///
    /// Failing a promise NIO has already resolved is a no-op —
    /// `EventLoopFuture._setError` ignores a second value — but closing a
    /// channel that finished its handshake is not, so the timer is cancelled the
    /// moment the handshake settles either way. Both the timer and the
    /// completion callback run on `child.eventLoop`, so there is no interleaving
    /// between them to reason about.
    private static func scheduleHandshakeDeadline(
        for child: any Channel,
        promise handshake: EventLoopPromise<Void>
    ) {
        let deadline = child.eventLoop.scheduleTask(in: handshakeTimeout) {
            handshake.fail(SyncTLSError.handshakeTimedOut)
            child.close(promise: nil)
        }
        handshake.futureResult.whenComplete { _ in deadline.cancel() }
    }

    /// Appends a refusal, dropping the oldest once the log is full.
    private static func record(_ reason: String, in log: NIOLockedValueBox<[String]>) {
        log.withLockedValue { entries in
            entries.append(reason)
            if entries.count > refusalLogLimit {
                entries.removeFirst(entries.count - refusalLogLimit)
            }
        }
    }
}
