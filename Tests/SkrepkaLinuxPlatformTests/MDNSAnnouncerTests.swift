import Foundation
import NIOCore
import SkrepkaSync
import Testing

@testable import SkrepkaLinuxPlatform

/// The announcer's reaction to a rival, driven through
/// ``MDNSAnnouncer/assume(_:attempt:)`` and ``MDNSAnnouncer/receive(_:on:)``
/// with no socket open: renaming, giving up, ignoring what is not mDNS, and a
/// stop that overtakes a rename.
@Suite("mDNS announcer conflicts", .serialized)
struct MDNSAnnouncerTests {
    static func descriptor() throws -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: "steamdeck",
            port: 7011,
            deviceID: try #require(SyncDeviceID(hex: String(repeating: "7", count: 64))),
            platform: .linux
        )
    }

    /// Another host's SRV for `<name>._skrepka._tcp.local`.
    static func rival(for instance: String, fromPort port: Int) throws -> MDNSSocket.Packet {
        let srv = DNSRecordData.SRV(priority: 0, weight: 0, port: 9, target: DNSName("elsewhere", "local"))
        let record = DNSRecord(
            name: MDNSServiceRecords.serviceType.prefixed(by: instance),
            data: .srv(srv),
            ttl: 120,
            cacheFlush: true
        )
        let message = DNSMessage(flags: DNSMessage.responseFlags, answers: [record])
        return MDNSSocket.Packet(
            bytes: DNSWriter.encode(message),
            source: try SocketAddress(ipAddress: "192.168.1.9", port: port)
        )
    }

    @Test("a conflict renames to the next name")
    func renames() async throws {
        let announcer = MDNSAnnouncer()
        try await announcer.assume(Self.descriptor(), attempt: 1)
        await announcer.receive(try Self.rival(for: "steamdeck", fromPort: 5353), on: 0)
        #expect(await announcer.registration == nil)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await announcer.registration?.name == "steamdeck #2")
        await announcer.stop()
    }

    @Test("a response from a port other than 5353 is not mDNS and cannot take the name")
    func ignoresOtherSourcePorts() async throws {
        let announcer = MDNSAnnouncer()
        try await announcer.assume(Self.descriptor(), attempt: 1)
        await announcer.receive(try Self.rival(for: "steamdeck", fromPort: 5354), on: 0)
        #expect(await announcer.registration?.name == "steamdeck")
        await announcer.stop()
    }

    @Test("running out of names is reported as a loss")
    func reportsExhaustion() async throws {
        let announcer = MDNSAnnouncer()
        let last = MDNSAnnouncer.nameAttempts
        try await announcer.assume(Self.descriptor(), attempt: last)
        await announcer.receive(try Self.rival(for: "steamdeck #\(last)", fromPort: 5353), on: 0)
        let loss = try await MDNSSocketSmokeTests.first(from: announcer.losses) { _ in true }
        #expect(loss == .namesTaken(attempts: last))
        #expect(await announcer.registration == nil)
    }

    @Test("a stop during a rename leaves nothing claimed afterwards")
    func stopOvertakesRename() async throws {
        let announcer = MDNSAnnouncer()
        try await announcer.assume(Self.descriptor(), attempt: 1)
        await announcer.receive(try Self.rival(for: "steamdeck", fromPort: 5353), on: 0)
        await announcer.stop()
        try await Task.sleep(for: .seconds(1.5))
        #expect(await announcer.registration == nil)
    }
}
