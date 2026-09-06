import Foundation
import NIOConcurrencyHelpers
import NIOCore

/// One authenticated tunnel to one peer.
///
/// An actor because ``receive()`` advances a single stream iterator: a
/// request/response protocol where two callers could take each other's replies
/// is not a protocol. Serialising reads here is what makes
/// ``SyncPeer/request(_:awaiting:)`` correct without a correlation identifier
/// on every message.
public actor SyncConnection {
    /// The device on the far end, as proved by the certificate it presented —
    /// not as claimed in any message.
    public nonisolated let peerDeviceID: SyncDeviceID
    /// The exact bytes that hash to ``peerDeviceID``.
    public nonisolated let peerCertificateDER: Data

    /// The policy this connection's certificate was accepted under, kept for the
    /// life of the connection.
    ///
    /// Carried rather than checked once and forgotten, because it is what makes
    /// ``PinPolicy/pairing``'s "must do nothing except pair" a property of the
    /// transport instead of a promise in a doc comment. A connection that
    /// accepted an unconfirmed certificate cannot be talked into serving an
    /// index by any caller, however wired.
    public nonisolated let policy: PinPolicy

    private let channel: any Channel
    private let frames: Mailbox<Frame>
    private let diagnostics: SyncConnectionDiagnostics

    init(
        channel: any Channel,
        peerDeviceID: SyncDeviceID,
        peerCertificateDER: Data,
        policy: PinPolicy,
        frames: Mailbox<Frame>,
        diagnostics: SyncConnectionDiagnostics
    ) {
        self.channel = channel
        self.peerDeviceID = peerDeviceID
        self.peerCertificateDER = peerCertificateDER
        self.policy = policy
        self.frames = frames
        self.diagnostics = diagnostics
    }

    /// The next message, or nil once the peer has gone.
    ///
    /// Frames whose body does not decode are counted and skipped rather than
    /// thrown: ``FrameError/malformedBody(reason:)`` is raised after the frame
    /// has been consumed, so the stream is still on a boundary and one bad
    /// frame from a peer must not end a session. What was skipped is readable
    /// through ``diagnosticsSnapshot()``.
    ///
    /// A message ``policy`` does not permit is the other kind of refusal: the
    /// connection is closed here and now, and
    /// ``SyncPolicyError/peerSentOutsidePairing(_:)`` is thrown to whoever was
    /// reading. Closing rather than only throwing is what makes the drop real —
    /// a throw alone leaves a hostile peer holding an open socket.
    ///
    /// The refusal is checked before the mailbox rather than after, so that
    /// frames the peer pipelined behind the offending one — they arrive in the
    /// same segment and are already queued by the time the channel closes — go
    /// with the connection instead of being handed out afterwards. A drop that
    /// still delivers the rest of the batch is not a drop.
    ///
    /// A peer that pipelines past ``Mailbox``'s ceiling is a third kind: the
    /// channel is closed from the mailbox's overflow handler and
    /// ``SyncTransportError/inboundQueueOverflow(capacity:)`` is recorded, so
    /// this method drains what was already queued and then throws it in place of
    /// the nil that would otherwise read as an ordinary hang-up.
    public func receive() async throws -> SyncMessage? {
        if let refusal = diagnostics.pairingRefusal { throw refusal }
        while let frame = await frames.next() {
            let message: SyncMessage
            do {
                message = try FrameCodec.message(from: frame)
            } catch FrameError.malformedBody(let reason) {
                diagnostics.recordMalformedBody(reason)
                continue
            }
            guard policy.permits(message.type) else {
                diagnostics.recordRefusalOutsidePairing(message.type)
                await close()
                throw SyncPolicyError.peerSentOutsidePairing(message.type)
            }
            return message
        }
        if let failure = diagnostics.failure { throw failure }
        return nil
    }

    /// Encodes and writes one message, or refuses it because ``policy`` does not
    /// carry it.
    ///
    /// The refusal is here rather than in ``SyncInitiator`` so that it holds for
    /// every writer this connection will ever have. A rule enforced only where
    /// today's caller happens to sit is a rule tomorrow's caller does not have.
    public func send(_ message: SyncMessage) async throws {
        guard policy.permits(message.type) else {
            throw SyncPolicyError.refusedToSendOutsidePairing(message.type)
        }
        let encoded = try FrameCodec.encode(message)
        var buffer = channel.allocator.buffer(capacity: encoded.count)
        buffer.writeBytes(encoded)
        try await channel.writeAndFlush(buffer).get()
    }

    /// Writes bytes straight into the tunnel, bypassing ``FrameCodec`` and the
    /// ``policy`` check in ``send(_:)``.
    ///
    /// Internal, and there because two things can only be tested from outside
    /// the encoder: a length prefix it refuses to produce, and a peer that
    /// ignores the outbound half of the pairing rule. Bypassing the check is the
    /// point — a test needs to be able to act as the hostile peer whose frames
    /// ``receive()`` has to refuse. Nothing in the protocol may use it.
    func sendUnframed(_ bytes: [UInt8]) async throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try await channel.writeAndFlush(buffer).get()
    }

    public func close() async {
        // An already-closed channel throws `ChannelError.alreadyClosed`, which
        // is the outcome this method was asked for.
        try? await channel.close().get()
    }

    /// What this connection tolerated rather than failed on: frame types it did
    /// not recognise, and bodies it could not decode.
    public func diagnosticsSnapshot() -> SyncConnectionDiagnostics.Snapshot {
        diagnostics.snapshot()
    }
}

/// The counters a ``SyncConnection`` keeps for the frames it survived.
///
/// A class shared with the channel handlers, which run on an event loop and
/// cannot await the actor. Exposed rather than logged because `SkrepkaSync`
/// builds on Linux and has no logger of its own; the app target reads these and
/// logs them through whichever facility its platform has.
public final class SyncConnectionDiagnostics: Sendable {
    public struct Snapshot: Sendable, Hashable {
        /// Type bytes this build does not know, in arrival order.
        public let unknownFrameTypes: [UInt8]
        /// Why each undecodable body was rejected, in arrival order.
        public let malformedBodies: [String]
        /// Messages the peer sent that ``SyncConnection/policy`` does not carry,
        /// in arrival order.
        ///
        /// Inbound only. The outbound half of the same rule never reaches a wire
        /// and is thrown straight at the caller that broke it, so recording it
        /// here would put this device's own bug in a list of things a peer did.
        ///
        /// At most one, since the first ends the connection — a list rather than
        /// an optional so it reads like the two counters above it.
        public let refusedOutsidePairing: [SyncMessageType]
    }

    private struct State: Sendable {
        var unknownFrameTypes: [UInt8] = []
        var malformedBodies: [String] = []
        var refusedOutsidePairing: [SyncMessageType] = []
        var failure: (any Error)?
    }

    private let state = NIOLockedValueBox(State())

    public init() {}

    /// The error that ended the stream, if one did.
    var failure: (any Error)? { state.withLockedValue { $0.failure } }

    func recordUnknownFrame(_ rawValue: UInt8) {
        state.withLockedValue { $0.unknownFrameTypes.append(rawValue) }
    }

    func recordMalformedBody(_ reason: String) {
        state.withLockedValue { $0.malformedBodies.append(reason) }
    }

    func recordFailure(_ error: any Error) {
        state.withLockedValue { if $0.failure == nil { $0.failure = error } }
    }

    /// The first message the peer sent that its connection's policy does not
    /// carry, as the error ``SyncConnection/receive()`` answers with from then
    /// on.
    ///
    /// Separate from ``failure``, which is what the channel reported. This one
    /// is a decision this side took, and keeping the two apart is what lets
    /// "we refused them" stay distinguishable from "the socket broke".
    var pairingRefusal: SyncPolicyError? {
        state.withLockedValue {
            $0.refusedOutsidePairing.first.map(SyncPolicyError.peerSentOutsidePairing)
        }
    }

    func recordRefusalOutsidePairing(_ type: SyncMessageType) {
        state.withLockedValue { $0.refusedOutsidePairing.append(type) }
    }

    public func snapshot() -> Snapshot {
        state.withLockedValue {
            Snapshot(
                unknownFrameTypes: $0.unknownFrameTypes,
                malformedBodies: $0.malformedBodies,
                refusedOutsidePairing: $0.refusedOutsidePairing
            )
        }
    }
}
