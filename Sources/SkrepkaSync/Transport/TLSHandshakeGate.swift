import Foundation
import NIOCore
import NIOTLS

/// Holds a connection back until the TLS handshake has actually completed.
///
/// Without it, `connect` returns as soon as TCP is up and the pinning callback
/// has not run — so a refused certificate arrives later as a channel that
/// quietly closes, which is indistinguishable from a peer going to sleep. The
/// gate turns it into a thrown error at the point the caller asked for a
/// connection.
///
/// It settles exactly once, and in the failure direction on either an error or
/// an unexpected close. A gate that could settle successfully after an error
/// would hand back a connection whose peer was never verified.
final class TLSHandshakeGate: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let promise: EventLoopPromise<Void>
    private var settled = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            settle(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        settle(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        settle(.failure(SyncTLSError.handshakeIncomplete))
        context.fireChannelInactive()
    }

    private func settle(_ result: Result<Void, any Error>) {
        guard !settled else { return }
        settled = true
        promise.completeWith(result)
    }
}
