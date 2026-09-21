import DBUS

/// The write side of the connection ``DaemonService`` gives `DBusObjectServer`.
///
/// A seam, so the fire-and-forget contract below can be tested without a live
/// bus: `DBusClient.Connection` has no public initialiser, so a test cannot
/// build one, but it can build a fake ``BusReplyWriter``.
protocol BusReplyWriter: Sendable {
    /// Writes `request` to the bus and returns once the bytes are on the wire —
    /// **without** waiting for a reply to it.
    func writeReply(_ request: DBusRequest) async throws
    /// Installs the connection's inbound-message handler.
    func installMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async
}

extension DBusClient.Connection: BusReplyWriter {
    func writeReply(_ request: DBusRequest) async throws {
        // `send.send(_:)` is the `Send` writer: it writes and returns a serial.
        // This is the whole point — see ``BusReplyConnection``.
        _ = try await send.send(request)
    }

    func installMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async {
        await setMessageHandler(handler)
    }
}

/// A server-side view of a connection whose replies are written and forgotten,
/// never awaited.
///
/// ## Why this exists
///
/// `DBusObjectServer` answers a method call by calling `connection.send(reply)`
/// on whatever ``DBUS/DBusServerConnection`` it was built with. Handing it the
/// live `DBusClient.Connection` — the obvious thing to do — routes that reply
/// through `Connection.send(_:timeoutNanoseconds:)`, which registers a reply
/// continuation and then *waits for a reply to the method return*. A method
/// return never gets a reply, so the send parks forever.
///
/// That park is fatal rather than merely wasteful, because the send runs inside
/// the connection's own read loop: `Connection.run()` awaits the message
/// handler inline (`DBusClient.swift`), and our handler is what calls
/// `server.handle(_:)`, which calls `connection.send(reply)`. So the read loop
/// never returns to read a second message, and the daemon answers exactly one
/// method call for the life of the process — which is the one-call hang.
///
/// The fix is to send a server reply the way a signal is sent: straight to the
/// `Send` writer, which returns once the bytes are on the wire and waits for
/// nothing. This wrapper is that redirection and nothing else.
struct BusReplyConnection<Writer: BusReplyWriter>: DBusServerConnection {
    let writer: Writer

    /// Writes `request` and returns without awaiting a reply.
    ///
    /// Every request the object server sends here is a reply itself — a method
    /// return, an error, an introspection answer — and a reply expects none of
    /// its own, so there is nothing to await. Awaiting is exactly the hang this
    /// type removes. The nil return is what `DBusObjectServer` expects: it
    /// discards the value.
    func send(_ request: DBusRequest) async throws -> DBusMessage? {
        try await writer.writeReply(request)
        return nil
    }

    /// Forwarded to the underlying writer.
    ///
    /// `DBusObjectServer` never calls this — ``DaemonService`` installs the
    /// handler on the live connection itself and routes messages here through
    /// `handle(message:)`. Forwarded rather than ignored so the type stays a
    /// faithful ``DBUS/DBusServerConnection`` if that ever stops being true.
    func setMessageHandler(_ handler: @escaping @Sendable (DBusMessage) async -> Void) async {
        await writer.installMessageHandler(handler)
    }
}
