import DBUS
import Testing

@testable import SkrepkaDaemon

/// The seam the one-call hang lived at.
///
/// `DBusObjectServer` answers a method call by calling `connection.send(reply)`.
/// Given the live `DBusClient.Connection`, that reply goes through
/// `Connection.send(_:)`, which waits for a reply *to the method return* — a
/// reply that never comes — and parks the connection's read loop, so the daemon
/// answers exactly one call for the life of the process. ``BusReplyConnection``
/// is the fix: it writes the reply and returns, waiting for nothing.
///
/// This is the deterministic half of the coverage; the end-to-end proof is the
/// `busctl … InterfaceVersion` / `skrepka list` repro, which cannot be a unit
/// test because it needs a live bus and a `DBusMessage` the library gives no
/// way to fabricate.
@Suite("Server replies are written, not awaited")
struct BusReplyConnectionTests {
    /// Records what it was asked to write, and never blocks — the fix's writer.
    private actor RecordingWriter: BusReplyWriter {
        private(set) var writes = 0
        func writeReply(_ request: DBusRequest) async throws { writes += 1 }
        func installMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async {}
    }

    /// Models the pre-fix path: `send` writes the reply and then waits — the
    /// live connection waited for a reply to it, this waits on a sleep. What
    /// matters is only that it does not return on its own.
    private struct AwaitingConnection: DBusServerConnection {
        func send(_ request: DBusRequest) async throws -> DBusMessage? {
            try await Task.sleep(for: .seconds(3600))
            return nil
        }
        func setMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async {}
    }

    private static func anyRequest() -> DBusRequest {
        DBusRequest.createMethodCall(
            destination: "dev.soldunov.Skrepka",
            path: "/dev/soldunov/Skrepka",
            interface: "dev.soldunov.Skrepka1",
            method: "InterfaceVersion"
        )
    }

    @Test("send writes the reply and returns without waiting for a reply to it")
    func sendIsFireAndForget() async throws {
        let writer = RecordingWriter()
        let connection = BusReplyConnection(writer: writer)
        let reply = try await connection.send(Self.anyRequest())
        #expect(reply == nil)
        #expect(await writer.writes == 1)
    }

    @Test("the wrapper returns where a connection that awaits its reply would hang")
    func theWrapperDoesNotParkWhereTheRawConnectionWould() async throws {
        // The bug: a `send` that waits for a reply to a reply never returns, so
        // a bounded wait around it times out.
        await #expect(throws: TimedOut.self) {
            try await Self.withDeadline(.milliseconds(500)) {
                _ = try await AwaitingConnection().send(Self.anyRequest())
            }
        }

        // The fix: the same call through `BusReplyConnection` returns well
        // inside the same kind of bound.
        let writer = RecordingWriter()
        try await Self.withDeadline(.seconds(5)) {
            _ = try await BusReplyConnection(writer: writer).send(Self.anyRequest())
        }
        #expect(await writer.writes == 1)
    }

    private struct TimedOut: Error {}

    /// Runs `work`, throwing ``TimedOut`` if it does not finish in `limit`. The
    /// losing branch is cancelled, and `AwaitingConnection` sleeps
    /// cancellably, so this returns rather than hanging the suite.
    private static func withDeadline(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
