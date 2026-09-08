import DBUS
import Foundation
import Logging

#if canImport(Glibc)
    import Glibc
#endif

/// Calls the daemon, one typed method per bus member.
///
/// Holds a connection rather than opening one per call, because `DBusClient`'s
/// connection API is scoped — see ``SkrepkaBus/withDaemon(logger:_:)``, which is
/// how a caller gets one of these.
///
/// Every method here is the same three steps: build a method call, send it,
/// read one value out of the reply. The steps are worth keeping visible rather
/// than folded into a generic helper, because the interesting part of each is
/// the argument types, which is exactly what a generic helper hides.
public struct DaemonProxy: Sendable {
    private let connection: DBusClient.Connection
    private let timeout: Duration

    /// - Parameter timeout: How long one member call waits for its reply.
    ///   `DBusClient` imposes no deadline of its own, so without this a CLI
    ///   run against a wedged daemon hangs rather than reporting.
    public init(connection: DBusClient.Connection, timeout: Duration = SkrepkaBus.callTimeout) {
        self.connection = connection
        self.timeout = timeout
    }

    // MARK: - Reading

    /// The interface version the daemon exports.
    ///
    /// Worth calling first from anything long-lived: an "unknown method" error
    /// reads exactly like a daemon that is not running, and this distinguishes
    /// them in one round trip.
    public func interfaceVersion() async throws -> UInt32 {
        let reply = try await call(SkrepkaInterface.Member.interfaceVersion)
        guard case .uint32(let version) = reply.first else {
            throw IPCError.unexpectedReply(member: SkrepkaInterface.Member.interfaceVersion)
        }
        return version
    }

    /// History, newest first with pinned entries hoisted. `limit` of 0 is every
    /// entry.
    public func history(limit: UInt32 = 0) async throws -> HistoryDocument {
        try await document(HistoryDocument.self, SkrepkaInterface.Member.history, .uint32(limit))
    }

    public func peers() async throws -> PeersDocument {
        try await document(PeersDocument.self, SkrepkaInterface.Member.peers)
    }

    public func diagnostics() async throws -> DiagnosticsDocument {
        try await document(DiagnosticsDocument.self, SkrepkaInterface.Member.diagnostics)
    }

    // MARK: - Acting

    public func copy(_ selector: ClipSelector) async throws -> ActionDocument {
        try await document(
            ActionDocument.self, SkrepkaInterface.Member.copy, .string(selector.wireValue))
    }

    public func submit(_ request: SubmitRequest) async throws -> ActionDocument {
        let json = try SkrepkaDocumentCoding.encode(request)
        return try await document(ActionDocument.self, SkrepkaInterface.Member.submit, .string(json))
    }

    public func syncNow() async throws -> ActionDocument {
        try await document(ActionDocument.self, SkrepkaInterface.Member.syncNow)
    }

    public func unpair(fingerprint: String) async throws -> ActionDocument {
        try await document(
            ActionDocument.self, SkrepkaInterface.Member.unpair, .string(fingerprint))
    }

    // MARK: - Pairing

    public func openPairing(seconds: UInt32) async throws -> PairingWindowDocument {
        try await document(
            PairingWindowDocument.self, SkrepkaInterface.Member.openPairing, .uint32(seconds))
    }

    public func closePairing() async throws -> ActionDocument {
        try await document(ActionDocument.self, SkrepkaInterface.Member.closePairing)
    }

    public func pair(with fingerprint: String) async throws -> PairingProposalDocument {
        try await document(
            PairingProposalDocument.self, SkrepkaInterface.Member.pairWith, .string(fingerprint))
    }

    public func confirmPairing(deviceID: String, accept: Bool) async throws -> ActionDocument {
        try await document(
            ActionDocument.self,
            SkrepkaInterface.Member.confirmPairing,
            .string(deviceID),
            .boolean(accept)
        )
    }

    /// Every pairing a peer starts against this device, until the caller stops
    /// reading.
    ///
    /// The bus does not deliver a signal to a connection that has not asked for
    /// it, so this adds the match rule as well as subscribing. `AddMatch` is
    /// sent once per call; a caller that wants two streams of the same signal
    /// gets two rules, which the bus deduplicates by reference count.
    public func pairingRequests() async throws -> AsyncStream<PairingProposalDocument> {
        let rule = """
            type='signal',sender='\(SkrepkaInterface.busName)',\
            interface='\(SkrepkaInterface.name)',\
            member='\(SkrepkaInterface.Signal.pairingRequested)'
            """
        try await addMatch(rule)
        let signals = await connection.subscribeToSignal(
            interface: SkrepkaInterface.name,
            member: SkrepkaInterface.Signal.pairingRequested
        )
        return AsyncStream { continuation in
            let task = Task {
                for await message in signals {
                    guard case .string(let json) = message.body.first else { continue }
                    // A signal this build cannot read is skipped rather than
                    // ending the stream: the next one may be from a member it
                    // does understand, and a CLI waiting to pair should not
                    // exit because one malformed broadcast arrived.
                    guard
                        let proposal = try? SkrepkaDocumentCoding.decode(
                            PairingProposalDocument.self, from: json)
                    else { continue }
                    continuation.yield(proposal)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func addMatch(_ rule: String) async throws {
        _ = try await send(
            DBusRequest.createMethodCall(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                method: "AddMatch",
                body: [.string(rule)]
            ),
            member: "AddMatch"
        )
    }

    private func document<Document: SkrepkaDocument>(
        _ type: Document.Type,
        _ member: String,
        _ arguments: DBusValue...
    ) async throws -> Document {
        let reply = try await call(member, arguments)
        guard case .string(let json) = reply.first else {
            throw IPCError.unexpectedReply(member: member)
        }
        return try SkrepkaDocumentCoding.decode(type, from: json)
    }

    private func call(_ member: String, _ arguments: [DBusValue] = []) async throws -> [DBusValue] {
        let request = DBusRequest.createMethodCall(
            destination: SkrepkaInterface.busName,
            path: SkrepkaInterface.objectPath,
            interface: SkrepkaInterface.name,
            method: member,
            body: arguments
        )
        guard let reply = try await send(request, member: member) else {
            throw IPCError.noReply(member: member)
        }
        guard reply.messageType != .error else {
            throw IPCError.busError(member: member, name: reply.errorName ?? "", detail: reply.errorDetail)
        }
        return reply.body
    }

    /// Every request goes out with ``timeout`` on it, and the library's
    /// deadline error becomes one the CLI can give advice about — `DBusError`
    /// reaching the user as `String(describing:)` says nothing they can act on.
    private func send(_ request: DBusRequest, member: String) async throws -> DBusMessage? {
        do {
            return try await connection.send(
                request, timeoutNanoseconds: SkrepkaBus.nanoseconds(timeout))
        } catch DBusError.timeout {
            throw IPCError.timedOut(member: member, after: timeout)
        }
    }
}

extension DBusMessage {
    /// The `errorName` header, which the library carries but exposes no
    /// accessor for.
    var errorName: String? {
        guard
            case .string(let name) = headerFields.first(where: { $0.code == .errorName })?
                .variant.value
        else { return nil }
        return name
    }

    /// The human half of an error reply. D-Bus convention puts it first in the
    /// body as a string; a service that omits it is within its rights.
    var errorDetail: String {
        guard case .string(let detail) = body.first else { return "" }
        return detail
    }
}
