import Foundation
import NIOCore
import NIOPosix
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// The announcer on real sockets: UDP 5353, the 224.0.0.251 group and the
/// kernel's multicast loopback, inside whatever network namespace the tests run
/// in (the Linux build container's `eth0`).
///
/// It proves the sockets bind beside each other, join, hear a query sent to
/// the group, and answer — by unicast to a legacy querier and by multicast to
/// the group. It cannot prove a Mac on a real LAN hears the answer; that is the
/// on-device check.
@Suite("mDNS over a real socket", .serialized)
struct MDNSSocketSmokeTests {
    static let interface = (try? MDNSInterface.current())?.first
    static let timeout: Duration = .seconds(5)

    @Test(
        "an announcement reaches the group, and a legacy query is answered by unicast",
        .enabled(if: interface != nil))
    func answersOnTheWire() async throws {
        let interface = try #require(Self.interface)
        let deviceID = try #require(SyncDeviceID(hex: String(repeating: "5", count: 64)))
        let descriptor = ServiceDescriptor(
            displayName: "smoke test", port: 7011, deviceID: deviceID, platform: .linux, pairingPort: 7012)

        // A second socket on the group, as another responder on this host would
        // have — avahi, on a Deck.
        let listener = try await MDNSSocket.open(on: interface, group: MultiThreadedEventLoopGroup.singleton)
        let announcer = MDNSAnnouncer()
        let querier = try await LegacyQuerier.open(on: interface)
        do {
            let registration = try await announcer.start(descriptor)
            #expect(registration.name == "smoke test")
            try await expectAnnouncement(on: listener)
            try await expectLegacyAnswer(from: querier)
        } catch {
            Issue.record(error)
        }
        await announcer.stop()
        await listener.close()
        await querier.close()
    }

    private func expectAnnouncement(on listener: MDNSSocket) async throws {
        let announced = try await Self.first(from: listener.packets) { packet in
            guard let message = try? DNSReader.decode(packet.bytes), message.isResponse else { return false }
            return message.answers.contains {
                $0.data == .ptr(DNSName("smoke test", "_skrepka", "_tcp", "local"))
            }
        }
        let message = try DNSReader.decode(announced.bytes)
        #expect(message.answers.contains { $0.data.type == DNSType.txt && $0.cacheFlush })
        #expect(announced.source.port == 5353)
    }

    private func expectLegacyAnswer(from querier: LegacyQuerier) async throws {
        let query = DNSMessage(
            id: 0x4242,
            flags: DNSMessage.queryFlags,
            questions: [DNSQuestion(name: MDNSServiceRecords.serviceType, type: DNSType.ptr)]
        )
        try await querier.send(DNSWriter.encode(query))
        let reply = try await Self.first(from: querier.replies) { _ in true }
        let message = try DNSReader.decode(reply)
        #expect(message.id == 0x4242)
        #expect(
            message.answers.contains { $0.data == .ptr(DNSName("smoke test", "_skrepka", "_tcp", "local")) })
        #expect(message.additionals.contains { $0.data.type == DNSType.srv })
    }

    /// The first element of `stream` that `wanted` accepts, or a failure after
    /// ``timeout``.
    static func first<Element: Sendable>(
        from stream: AsyncStream<Element>,
        where wanted: @escaping @Sendable (Element) -> Bool
    ) async throws -> Element {
        try await withThrowingTaskGroup(of: Element.self) { group in
            group.addTask {
                for await element in stream where wanted(element) { return element }
                throw SmokeFailure.streamEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SmokeFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SmokeFailure.timedOut }
            return first
        }
    }
}

enum SmokeFailure: Error {
    case timedOut
    case streamEnded
}

/// A one-shot resolver's socket: an ephemeral port, so RFC 6762 §6.7 applies.
struct LegacyQuerier {
    let channel: any Channel
    let replies: AsyncStream<[UInt8]>

    static func open(on interface: MDNSInterface) async throws -> LegacyQuerier {
        let (replies, sink) = AsyncStream<[UInt8]>.makeStream()
        let channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(ReplyCollector(sink: sink))
                }
            }
            .bind(host: "0.0.0.0", port: 0)
            .get()
        let options = try #require(channel as? any SocketOptionProvider)
        let first = try #require(interface.addresses.first)
        var address = in_addr()
        address.s_addr = first.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        try await options.setIPMulticastIF(address).get()
        return LegacyQuerier(channel: channel, replies: replies)
    }

    func send(_ bytes: [UInt8]) async throws {
        let group = try SocketAddress(ipAddress: MDNSSocket.groupAddress, port: MDNSSocket.port)
        let buffer = channel.allocator.buffer(bytes: bytes)
        try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: group, data: buffer)).get()
    }

    func close() async {
        // The test is over either way.
        try? await channel.close()
    }
}

private final class ReplyCollector: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let sink: AsyncStream<[UInt8]>.Continuation

    init(sink: AsyncStream<[UInt8]>.Continuation) {
        self.sink = sink
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        sink.yield(Array(unwrapInboundIn(data).data.readableBytesView))
    }
}
