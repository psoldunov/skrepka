import Foundation
import NIOCore
import NIOPosix

#if canImport(Glibc)
    import Glibc
#endif

/// One UDP socket on port 5353 for one interface, beside avahi's.
///
/// ## Sharing the port with avahi
///
/// `avahi-core/socket.c` binds its own socket with `SO_REUSEADDR` (and
/// `SO_REUSEPORT`) set precisely so another mDNS stack can bind the port too.
/// Linux lets two UDP sockets share an address when **both** set
/// `SO_REUSEADDR` whoever owns them, and refuses `SO_REUSEPORT` sharing across
/// user IDs — socket(7) — and avahi runs as its own user, so `SO_REUSEADDR` is
/// the one that does the work here.
///
/// **Bound to the group address, not the wildcard**, and this is what keeps the
/// two stacks from hurting each other. With both sockets on `0.0.0.0:5353` a
/// unicast datagram to the port reaches only one of them, and avahi would lose
/// the unicast answers its own QU queries ask for. A socket bound to
/// `224.0.0.251` matches no unicast destination, so every unicast packet still
/// goes to avahi and this socket sees only the group's traffic. Linux sources a
/// packet sent from a multicast-bound socket from the routing table's address
/// (`inet_bind` clears the source for a multicast bind), so replies still leave
/// with a real address and — RFC 6762 §11 — from port 5353.
///
/// **One socket per interface**, because the kernel picks a multicast
/// interface per socket (`IP_MULTICAST_IF`) and swift-nio writes no per-packet
/// `IP_PKTINFO`. `IP_MULTICAST_ALL` off makes each socket hear only the
/// interface it joined on, so the address it answers with is the one RFC 6762
/// §6.2 asks for.
///
/// swift-nio rather than raw Glibc sockets because the package already runs
/// its sync transport on it: this gets an event loop, non-blocking I/O and a
/// typed multicast API without a thread of its own.
struct MDNSSocket: Sendable {
    struct Packet: Sendable {
        let bytes: [UInt8]
        let source: SocketAddress
    }

    static let groupAddress = "224.0.0.251"
    static let port = 5353

    let interface: MDNSInterface
    let channel: any Channel
    let packets: AsyncStream<Packet>

    /// Opens, joins and configures the socket for one interface.
    static func open(on interface: MDNSInterface, group: any EventLoopGroup) async throws -> MDNSSocket {
        let (packets, sink) = AsyncStream<Packet>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let channel = try await DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(MDNSPacketHandler(sink: sink))
                }
            }
            .bind(host: groupAddress, port: port)
            .get()
        do {
            try await configure(channel, for: interface)
        } catch {
            try? await channel.close()
            throw error
        }
        return MDNSSocket(interface: interface, channel: channel, packets: packets)
    }

    private static func configure(_ channel: any Channel, for interface: MDNSInterface) async throws {
        guard let multicast = channel as? any MulticastChannel,
            let options = channel as? any SocketOptionProvider,
            let first = interface.addresses.first
        else { throw MDNSSocketError.unsupported }
        let group = try SocketAddress(ipAddress: groupAddress, port: port)
        try await multicast.joinGroup(group, device: interface.device).get()
        var address = in_addr()
        address.s_addr = first.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        try await options.setIPMulticastIF(address).get()
        // RFC 6762 §11: sent with an IP TTL of 255, multicast and unicast
        // alike, so a receiver can tell the packet came from the link.
        try await options.setIPMulticastTTL(255).get()
        try await channel.setOption(ipLevel(IP_TTL), value: 255).get()
        // Looped back so avahi on this machine sees the records too — which is
        // what makes `avahi-browse -r _skrepka._tcp` on the Deck show it.
        try await options.setIPMulticastLoop(1).get()
        try await channel.setOption(ipLevel(IP_MULTICAST_ALL), value: 0).get()
    }

    /// An `IPPROTO_IP` option swift-nio has no name for.
    private static func ipLevel(_ name: CInt) -> ChannelOptions.Types.SocketOption {
        ChannelOptions.Types.SocketOption(
            level: .init(rawValue: CInt(IPPROTO_IP)), name: .init(rawValue: name))
    }

    func sendMulticast(_ bytes: [UInt8]) async throws {
        try await send(bytes, to: try SocketAddress(ipAddress: Self.groupAddress, port: Self.port))
    }

    func send(_ bytes: [UInt8], to destination: SocketAddress) async throws {
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: destination, data: buffer)).get()
    }

    func close() async {
        // Nothing to do with a failure: the socket is being given up either way,
        // and NIO answers an already-closed channel with an error.
        try? await channel.close()
    }
}

enum MDNSSocketError: Error, CustomStringConvertible {
    case unsupported

    var description: String { "the mDNS socket could not be configured for multicast" }
}

/// Hands every datagram the socket receives to its ``MDNSSocket/packets``.
private final class MDNSPacketHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    let sink: AsyncStream<MDNSSocket.Packet>.Continuation

    init(sink: AsyncStream<MDNSSocket.Packet>.Continuation) {
        self.sink = sink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        sink.yield(.init(bytes: Array(envelope.data.readableBytesView), source: envelope.remoteAddress))
    }

    func channelInactive(context: ChannelHandlerContext) {
        sink.finish()
        context.fireChannelInactive()
    }

    /// A UDP socket's errors are per-datagram — an ICMP unreachable for a reply
    /// that went nowhere — and none of them ends the socket.
    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}
