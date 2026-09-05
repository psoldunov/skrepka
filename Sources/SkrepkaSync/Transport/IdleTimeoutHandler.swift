import NIOCore

/// Closes a connection that has gone quiet, on the event
/// `IdleStateHandler` fires.
///
/// `IdleStateHandler` only *reports* idleness — it schedules the timer and
/// fires `IdleStateHandler.IdleStateEvent` down the pipeline, and a pipeline
/// where nothing handles that event has a timer and no timeout. This is the
/// half that acts on it.
///
/// It exists because nothing else reaps a peer that stops speaking. A connection
/// that completes TLS and then goes silent holds a file descriptor, an
/// event-loop registration and a BoringSSL connection object for as long as the
/// process lives, and a few thousand of those are all it takes to stop the
/// daemon accepting the peer the user actually owns. Only the read direction is
/// watched: this side writes only in answer to something, so a write gap is this
/// device being idle rather than the peer being gone.
final class IdleTimeoutHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let idle = event as? IdleStateHandler.IdleStateEvent, case .read = idle {
            // No error is recorded: a peer that stopped talking is
            // indistinguishable from one that closed, and `FrameSink` already
            // ends the stream on `channelInactive`.
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}
