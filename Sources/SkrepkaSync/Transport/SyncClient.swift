import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Dials a peer.
///
/// Returns only once the TLS handshake has finished and the peer's certificate
/// has been pinned, so a `SyncConnection` in hand is always a connection to a
/// device this one has verified. A `connect` that returned earlier would make
/// "unpinned peer" arrive later as a channel that quietly closed, which reads
/// exactly like a laptop going to sleep.
public enum SyncClient {
    public static func connect(
        host: String,
        port: Int,
        identity: DeviceCertificate,
        policy: PinPolicy,
        group: any EventLoopGroup
    ) async throws -> SyncConnection {
        let context = try SyncTLS.context(for: SyncTLS.clientConfiguration(identity: identity))
        let wiring = SyncChannelWiring(policy: policy)
        let handshake = group.next().makePromise(of: Void.self)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                do {
                    // `serverHostname: nil` deliberately: there is no name to
                    // check. The peer is identified by the hash of the
                    // certificate it presents, and sending SNI would leak which
                    // device is being dialled to anything watching the segment.
                    let tls = try NIOSSLClientHandler(
                        context: context,
                        serverHostname: nil,
                        customVerificationCallback: SyncTLS.verificationCallback(
                            policy: policy,
                            verification: wiring.verification
                        )
                    )
                    try channel.pipeline.syncOperations.addHandlers(
                        [tls, TLSHandshakeGate(promise: handshake)] + wiring.inboundHandlers()
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            // The gate never reached the pipeline, so nothing else will ever
            // complete this promise — and NIO traps on one that is dropped
            // unfulfilled.
            handshake.fail(error)
            throw error
        }
        return try await wiring.connection(channel: channel, handshake: handshake.futureResult)
    }
}
