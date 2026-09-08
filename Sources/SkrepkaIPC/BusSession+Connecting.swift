import DBUS
import Logging

/// Which bus a session opens, how it opens one, and what that can fail with.
///
/// Split out of `BusSession.swift` so the lifetime machinery — the parked task,
/// the epoch, the invalidation — reads as one thing rather than as the larger
/// half of a file that also parses addresses.
extension BusSession {
    /// Which bus to open.
    public enum Bus: Sendable {
        /// `org.freedesktop.Avahi` lives here.
        case system
        /// Where `dev.soldunov.Skrepka` is exported, and where the desktop's
        /// own services live.
        case session
    }

    /// Why a session could not be opened.
    public enum SessionError: Error, Sendable, CustomStringConvertible {
        /// The bus refused the connection, or there was no bus to connect to.
        case cannotConnect(reason: String)
        /// The task ended without reporting either way.
        ///
        /// Reached when ``BusSession/stop()`` or ``BusSession/invalidate()``
        /// tears down the readiness stream while a connect is still in flight —
        /// not by cancelling the task that is awaiting `connection()`. Awaiting
        /// a `Task`'s value neither throws on the awaiting task's own
        /// cancellation nor cancels the awaited task, so a caller that cancels
        /// stays suspended until the handshake finishes either way. Reword this
        /// if that is ever made cancellable.
        case cancelled

        public var description: String {
            switch self {
            case .cannotConnect(let reason): "cannot connect to the bus: \(reason)"
            case .cancelled: "connecting to the bus was cancelled"
            }
        }
    }

    static func open(
        _ bus: Bus,
        address: String?,
        logger: Logger,
        _ body: @Sendable @escaping (DBusClient.Connection) async throws -> Void
    ) async throws {
        let auth = SkrepkaBus.authentication()
        if let address {
            let explicit = try parse(address)
            try await DBusClient.withConnection(to: explicit, auth: auth, logger: logger, body)
            return
        }
        switch bus {
        case .system:
            try await DBusClient.withSystemBus(auth: auth, logger: logger, body)
        case .session:
            try await DBusClient.withSessionBus(auth: auth, logger: logger, body)
        }
    }

    /// A bare path is the spelling everyone reaches for first, and
    /// `DBusAddress.parse` rejects it — so accept both rather than making the
    /// difference a caller's problem.
    static func parse(_ address: String) throws -> DBusAddress {
        if address.hasPrefix("/") { return .unix(path: address) }
        return try DBusAddress.parse(address)
    }
}
