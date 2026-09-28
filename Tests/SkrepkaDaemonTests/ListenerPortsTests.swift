import Foundation
import NIOCore
import NIOPosix
import SkrepkaIPC
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

#if canImport(Glibc)
    import Glibc
#endif

/// The ports a firewall rule has to name, and when the daemon may trade one
/// for a free one.
@Suite("Listener ports")
struct ListenerPortsTests {
    /// A NixOS firewall dropped every dial to the random ports this used to
    /// bind, and no rule could name them.
    @Test("With no --port, the listeners ask for Skrepka's own pair and may fall back")
    func defaultsToSkrepkasPorts() {
        let ports = ListenerPorts(configured: nil)
        #expect(ports.sync == 27182)
        #expect(ports.pairing == 27183)
        #expect([ports.sync, ports.pairing] == SkrepkaPorts.all)
        #expect(ports.mayFallBack)
    }

    @Test("--port N puts pairing on N+1 and binds exactly")
    func namedPortBindsExactly() {
        let ports = ListenerPorts(configured: 7011)
        #expect(ports.sync == 7011)
        #expect(ports.pairing == 7012)
        #expect(!ports.mayFallBack)
    }

    @Test("--port 0 asks for free ports for both")
    func zeroMeansFreePorts() {
        let ports = ListenerPorts(configured: 0)
        #expect(ports.sync == 0)
        #expect(ports.pairing == 0)
        #expect(!ports.mayFallBack)
    }

    /// Another program on 27182 must not take capture down with sync.
    @Test("Skrepka's own port, when taken, is traded for a free one")
    func defaultPortFallsBackWhenTaken() async throws {
        let fixture = try await Fixture()
        let server = try await ListenerPorts(configured: nil).bind(fixture.heldPort, start: fixture.start)
        #expect(server.port != fixture.heldPort)
        #expect(server.port != 0)
        await server.stop()
        try await fixture.close()
    }

    /// A port somebody named is what their firewall rule says; a free one
    /// instead would be a listener nobody can reach and a daemon that says
    /// nothing about it.
    @Test("A port --port named, when taken, is an error rather than a fallback")
    func namedPortDoesNotFallBack() async throws {
        let fixture = try await Fixture()
        let ports = ListenerPorts(configured: fixture.heldPort)
        await #expect {
            _ = try await ports.bind(fixture.heldPort, start: fixture.start)
        } throws: { error in
            (error as? IOError)?.errnoCode == EADDRINUSE
        }
        try await fixture.close()
    }

    /// A port held by a plain listener, and a way to start a sync listener.
    private struct Fixture {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let identity: DeviceCertificate
        let holder: any Channel

        var heldPort: Int { holder.localAddress?.port ?? 0 }

        init() async throws {
            identity = try DeviceCertificate.generate()
            // The daemon binds every interface, so the holder does too: a
            // holder on loopback alone would not collide with it everywhere.
            holder = try await ServerBootstrap(group: group)
                .bind(host: "0.0.0.0", port: 0)
                .get()
        }

        func start(_ port: Int) async throws -> SyncServer {
            try await SyncServer.start(
                identity: identity,
                policy: .pairing,
                host: "0.0.0.0",
                port: port,
                group: group
            )
        }

        func close() async throws {
            try await holder.close().get()
            try await group.shutdownGracefully()
        }
    }
}
