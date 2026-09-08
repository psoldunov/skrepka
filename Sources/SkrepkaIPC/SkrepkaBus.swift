import DBUS
import Foundation
import Logging

#if canImport(Glibc)
    import Glibc
#endif

/// Getting onto the session bus, from either end.
///
/// Scoped rather than a stored connection because that is the shape
/// `DBusClient` offers: the connection lives for the duration of a closure and
/// is torn down on the way out. For a CLI that is exactly right — one command,
/// one connection, exit. For the daemon it means the whole run happens inside
/// the closure, which ``DaemonHosting`` is the daemon-side name for.
public enum SkrepkaBus {
    /// What a call to a daemon that is not there costs before it gives up.
    ///
    /// `DBusClient` waits without a deadline of its own, and a CLI that hangs
    /// forever against a stopped daemon is worse than one that says so. Long
    /// enough that a busy daemon mid-sync still answers.
    public static let callTimeout: Duration = .seconds(10)

    /// A `Duration` as whole nanoseconds, which is the unit
    /// `DBusClient.Connection.send(_:timeoutNanoseconds:)` takes.
    ///
    /// Saturating rather than trapping: a negative or absurd `Duration` would
    /// be a programming error, and crashing the CLI over one is a worse answer
    /// than waiting.
    public static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        guard seconds >= 0 else { return 0 }
        let whole = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !whole.overflow else { return .max }
        let fraction = UInt64(max(0, attoseconds) / 1_000_000_000)
        let total = whole.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? .max : total.partialValue
    }

    /// EXTERNAL authentication, which on a Unix socket is the only mechanism a
    /// session bus accepts and needs no cookie file.
    ///
    /// The bus checks the peer credentials of the socket itself, so the user ID
    /// sent here has to be the process's real one — passing anything else fails
    /// the handshake rather than impersonating anybody.
    public static func authentication() -> AuthType {
        .external(userID: String(getuid()))
    }

    /// Runs `body` against the daemon on the session bus.
    ///
    /// Throws ``IPCError/daemonUnavailable(reason:)`` where the bus itself
    /// cannot be reached — no `DBUS_SESSION_BUS_ADDRESS` and no
    /// `XDG_RUNTIME_DIR`, which is what a `ssh` session with no lingering user
    /// session looks like. That is a different failure from a daemon that is
    /// not running, and the two want different advice.
    ///
    /// Throws ``IPCError/timedOut(member:after:)`` where something owns the
    /// name and does not answer inside ``callTimeout`` — a third failure again,
    /// and the one where telling the user to enable the unit is wrong.
    public static func withDaemon<R: Sendable>(
        logger: Logger = Logger(label: "skrepka.ipc"),
        _ body: @Sendable @escaping (DaemonProxy) async throws -> R
    ) async throws -> R {
        do {
            return try await DBusClient.withSessionBus(
                auth: authentication(),
                logger: logger
            ) { connection in
                try await body(DaemonProxy(connection: connection))
            }
        } catch let error as IPCError {
            throw error
        } catch let error as SkrepkaDocumentCoding.Failure {
            throw error
        } catch DBusError.timeout {
            // The handshake itself, rather than one member call — a bus that
            // accepted the socket and never answered `Hello`.
            throw IPCError.timedOut(member: "the session bus handshake", after: callTimeout)
        } catch {
            throw IPCError.daemonUnavailable(reason: String(describing: error))
        }
    }
}
