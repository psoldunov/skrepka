import Foundation
import NIOCore
import NIOPosix
import Testing

@testable import SkrepkaSync

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The classification every "could not connect" sentence is chosen from.
@Suite("Dial failure")
struct DialFailureTests {
    /// What a Mac logged dialling a NixOS machine whose firewall dropped the
    /// SYN: "Pairing failed: Connect timeout (10 s)".
    @Test("A connect that runs out of time is no answer")
    func timeoutIsNoAnswer() {
        #expect(DialFailure(ChannelError.connectTimeout(.seconds(10))) == .noAnswer)
    }

    /// The errno each address attempt inside a `NIOConnectionError` carries.
    @Test("A failed attempt is classified by errno")
    func classifiesSocketErrors() {
        #expect(DialFailure(errno: ECONNREFUSED) == .refused)
        #expect(DialFailure(errno: ETIMEDOUT) == .noAnswer)
        for code in [EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL] {
            #expect(DialFailure(errno: code) == .unreachable)
        }
    }

    /// `SyncClient.connect` dials through Happy Eyeballs, which fails only as
    /// `NIOConnectionError` or `ChannelError.connectTimeout`. A bare `IOError`
    /// is a TLS handshake or an exchange that lost its connection after the
    /// connect worked — by then the pair request may already have gone out, so
    /// "did not answer" would be wrong and would send the user to a firewall.
    @Test("A socket error after the connect is not a dial failure")
    func ignoresSocketErrorsAfterTheConnect() {
        for code in [ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH] {
            #expect(DialFailure(IOError(errnoCode: code, reason: "read")) == nil)
        }
    }

    /// Everything after the TCP connect has its own, better sentence; folding
    /// one of those into "did not answer" would send a user to their firewall
    /// over a certificate that changed.
    @Test("Failures that are not about reaching the peer are left alone")
    func ignoresEverythingElse() {
        #expect(DialFailure(SyncTLSError.handshakeTimedOut) == nil)
        #expect(DialFailure(ChannelError.ioOnClosedChannel) == nil)
        #expect(DialFailure(IOError(errnoCode: EBADF, reason: "read")) == nil)
        #expect(DialFailure(CancellationError()) == nil)
    }

    /// Through the real dialer, so the shape NIO fails with is pinned rather
    /// than assumed: a refusal arrives wrapped in `NIOConnectionError`, one
    /// entry per address tried.
    ///
    /// Port 1 on loopback, because nothing in the suite can ever listen there:
    /// an unprivileged process cannot bind below 1024. A port freed a moment
    /// earlier was taken by another test's listener often enough under
    /// `--parallel` that this connected and failed on the handshake instead.
    @Test("Dialling a port with nothing listening is a refusal")
    func closedPortIsRefused() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let identity = try DeviceCertificate.generate()

        await #expect {
            _ = try await SyncClient.connect(
                host: "127.0.0.1",
                port: 1,
                identity: identity,
                policy: .pairing,
                group: group
            )
        } throws: { error in
            error is NIOConnectionError && DialFailure(error) == .refused
        }
        try await group.shutdownGracefully()
    }
}
