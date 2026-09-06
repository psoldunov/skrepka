import Foundation
import NIOCore

/// The last handler in the pipeline: turns decoded frames into elements of the
/// `AsyncStream` a ``SyncConnection`` reads.
///
/// It also decides what a decoder error costs. `FrameError` draws that line
/// itself, per case, and getting it backwards is either an infinite loop or a
/// peer that can hang up on you with one bad frame:
///
/// - ``FrameError/bodyTooLarge(declaredBytes:)`` and
///   ``FrameError/truncated`` are fatal. Neither consumed anything, so there is
///   no frame boundary left to resynchronise on and retrying the decode throws
///   forever. The channel closes.
/// - Everything else has already consumed its frame and is handled in
///   ``FrameDecoder`` or in ``SyncConnection``, so it never reaches here.
final class FrameSink: ChannelInboundHandler {
    typealias InboundIn = Frame

    private let deliver: @Sendable (Frame) -> Void
    private let finish: @Sendable () -> Void
    private let fail: @Sendable (any Error) -> Void

    init(
        deliver: @escaping @Sendable (Frame) -> Void,
        finish: @escaping @Sendable () -> Void,
        fail: @escaping @Sendable (any Error) -> Void
    ) {
        self.deliver = deliver
        self.finish = finish
        self.fail = fail
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        deliver(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        // `ByteToMessageHandler` fires the error and stops decoding but does
        // not close, so closing here is what stops a peer that declared a
        // 4 GB body from holding the socket open afterwards.
        context.close(promise: nil)
    }
}
