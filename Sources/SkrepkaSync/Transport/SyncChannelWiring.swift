import Foundation
import NIOCore

/// The pieces a channel and its ``SyncConnection`` share, built once per
/// connection and handed to both.
///
/// Exists so the client and the server assemble the *same* pipeline. Two
/// slightly different pipelines is how one side ends up enforcing a limit the
/// other does not.
struct SyncChannelWiring: Sendable {
    /// How long a pinned connection may go without a readable byte.
    ///
    /// Both ends of a pinned connection are machines taking turns, so a gap of
    /// minutes means one of them is gone rather than thinking. Closing costs a
    /// reconnect; not closing costs a descriptor that is never returned.
    static let pinnedReadTimeout = TimeAmount.seconds(120)

    /// The same, for a connection that may only pair.
    ///
    /// Longer, because what it is waiting on is a human reading eight
    /// characters off another screen. Tied to
    /// ``SyncLimits/pairingFreshnessWindow`` rather than picked separately: a
    /// pairing that outlasts that window is already refused as stale, so there
    /// is nothing left to hold the socket open for.
    static let pairingReadTimeout = TimeAmount.seconds(Int64(SyncLimits.pairingFreshnessWindow))

    /// The policy the verification callback enforces on the certificate, handed
    /// on to the connection so it enforces the same one on the messages.
    ///
    /// Taken here rather than at ``connection(channel:handshake:)`` for the
    /// reason this type exists at all: the client and the server must not be
    /// able to configure the callback from one policy and the connection from
    /// another.
    let policy: PinPolicy
    let verification = PeerVerification()
    let diagnostics = SyncConnectionDiagnostics()
    let frames = Mailbox<Frame>()

    init(policy: PinPolicy) {
        self.policy = policy
    }

    /// Everything below the TLS handler, in pipeline order.
    ///
    /// The two timeout handlers lead because inbound events travel head to
    /// tail: `IdleStateHandler` counts the reads and fires the event,
    /// ``IdleTimeoutHandler`` sits downstream of it and acts on the event. In
    /// the other order the event would travel away from the handler that has to
    /// see it, and the pipeline would have a timer and no timeout.
    func inboundHandlers() -> [any ChannelHandler] {
        let diagnostics = diagnostics
        let frames = frames
        return [
            IdleStateHandler(readTimeout: readTimeout),
            IdleTimeoutHandler(),
            ByteToMessageHandler(
                FrameDecoder(onUnknownFrame: { diagnostics.recordUnknownFrame($0) })
            ),
            FrameSink(
                deliver: { frames.deliver($0) },
                finish: { frames.finish() },
                fail: { diagnostics.recordFailure($0) }
            ),
        ]
    }

    /// Waits for the handshake, then turns the channel into a connection whose
    /// peer is known.
    ///
    /// The `guard` on ``PeerVerification/verifiedPeer`` is not defensive
    /// bookkeeping. A callback that never ran is exactly what a configuration
    /// with verification disabled looks like from out here, and the difference
    /// between refusing and shrugging at that is the difference between a
    /// transport that authenticates and one that does not.
    func connection(channel: any Channel, handshake: EventLoopFuture<Void>) async throws -> SyncConnection {
        closeOnInboundOverflow(channel)
        do {
            try await handshake.get()
        } catch {
            await close(channel)
            if case .refused(let reason) = verification.outcome { throw reason }
            throw error
        }

        guard let peer = verification.verifiedPeer else {
            await close(channel)
            throw SyncTLSError.handshakeIncomplete
        }

        return SyncConnection(
            channel: channel,
            peerDeviceID: peer.deviceID,
            peerCertificateDER: peer.certificateDER,
            policy: policy,
            frames: frames,
            diagnostics: diagnostics
        )
    }

    /// The read timeout a connection under this policy gets.
    private var readTimeout: TimeAmount {
        switch policy {
        case .pinned: Self.pinnedReadTimeout
        case .pairing: Self.pairingReadTimeout
        }
    }

    /// Wires the mailbox's ceiling to the socket.
    ///
    /// ``Mailbox`` can bound what it holds but cannot stop the peer filling it,
    /// because it has no channel — so this is where a peer that pipelines past a
    /// turn-taking protocol's ceiling loses the connection rather than just the
    /// frames. Installed before the handshake is awaited, so the window in which
    /// frames are capped but nothing closes is as short as the pipeline allows.
    private func closeOnInboundOverflow(_ channel: any Channel) {
        let diagnostics = diagnostics
        let frames = frames
        frames.onOverflow {
            diagnostics.recordFailure(
                SyncTransportError.inboundQueueOverflow(capacity: frames.capacity)
            )
            channel.close(promise: nil)
        }
    }

    /// Closing a channel that is already closed throws
    /// `ChannelError.alreadyClosed`, which is the state being asked for. There
    /// is nothing a caller could do differently and nothing worth reporting.
    private func close(_ channel: any Channel) async {
        try? await channel.close().get()
    }
}
