import DBUS
import Foundation

/// Makes sure `skrepkad` is running, for a client that would rather start it
/// than tell the user to.
///
/// ## Two ways it comes up, and why both
///
/// **D-Bus activation** is the ordinary one. `install.sh` puts
/// `dev.soldunov.Skrepka.service` in the user's D-Bus services directory, and
/// the bus then starts the daemon — through its systemd unit — the moment
/// anything calls it. Nothing here has to do anything for that to happen: the
/// first call below *is* the start.
///
/// **Starting the unit** covers the case activation cannot: an install from
/// before the activation file existed, or a bus that has not reloaded its
/// configuration since it was written. The call then answers
/// `ServiceUnknown`, and asking the user's systemd instance for
/// `skrepkad.service` directly is the same start by a longer road.
///
/// Anything else is reported rather than acted on. A daemon that owns the name
/// and does not answer is not helped by being started again, and a session bus
/// that cannot be reached cannot be asked to start anything.
public enum DaemonStarter {
    /// What happened.
    public enum Outcome: Sendable, Equatable {
        /// The daemon answered — perhaps because the call activated it.
        case running(version: UInt32)
        /// It was not running, and asking systemd started it.
        case started(version: UInt32)
        /// It is not running and could not be started. A sentence for a person.
        case failed(reason: String)
    }

    /// The systemd user unit `install.sh` installs.
    public static let unitName = "skrepkad.service"

    /// Answers once the daemon responds, or once it is clear it will not.
    ///
    /// - Parameter patience: How long a freshly started unit gets to claim its
    ///   name on the bus. The daemon claims it within a second of starting; five
    ///   is generous for a Steam Deck coming out of sleep.
    public static func ensureRunning(
        on session: BusSession,
        patience: Duration = .seconds(5)
    ) async -> Outcome {
        switch await probe(session) {
        case .answered(let version):
            return .running(version: version)
        case .broken(let reason):
            return .failed(reason: reason)
        case .notRunning:
            break
        }
        // Not running, and activation — if the bus has the file — did not
        // start it: ask systemd for the unit.
        do {
            try await startUnit(on: session)
        } catch {
            return .failed(reason: reason(forFailedStart: error))
        }
        return await waitForName(on: session, patience: patience)
    }

    /// One call, sorted into the three answers that lead somewhere different.
    private enum Probe {
        case answered(UInt32)
        case notRunning
        case broken(String)
    }

    private static func probe(_ session: BusSession) async -> Probe {
        do {
            return .answered(try await version(on: session))
        } catch let error as IPCError where error.isDaemonNotRunning {
            return .notRunning
        } catch {
            return .broken(String(describing: error))
        }
    }

    private static func version(on session: BusSession) async throws -> UInt32 {
        try await SkrepkaBus.proxy(on: session).interfaceVersion()
    }

    private static func waitForName(on session: BusSession, patience: Duration) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now + patience
        while !Task.isCancelled && clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                break
            }
            switch await probe(session) {
            case .answered(let version):
                return .started(version: version)
            case .notRunning:
                continue
            case .broken(let reason):
                return .failed(reason: reason)
            }
        }
        if Task.isCancelled {
            return .failed(reason: "waiting for skrepkad was cancelled")
        }
        return .failed(
            reason: """
                skrepkad was started but did not answer within \(patience.components.seconds) seconds. \
                See what it logged with: journalctl --user -u skrepkad
                """)
    }

    /// `org.freedesktop.systemd1.Manager.StartUnit`, on the user's own
    /// systemd instance — which is on the session bus, so the connection the
    /// daemon's calls use is the one that asks.
    private static func startUnit(on session: BusSession) async throws {
        let member = "StartUnit"
        let request = DBusRequest.createMethodCall(
            destination: "org.freedesktop.systemd1",
            path: "/org/freedesktop/systemd1",
            interface: "org.freedesktop.systemd1.Manager",
            method: member,
            body: [.string(unitName), .string("replace")]
        )
        let connection: DBusClient.Connection
        do {
            connection = try await session.connection()
        } catch let error as BusSession.SessionError {
            throw IPCError.daemonUnavailable(reason: error.description)
        }
        let reply: DBusMessage?
        do {
            reply = try await connection.send(
                request, timeoutNanoseconds: SkrepkaBus.nanoseconds(SkrepkaBus.callTimeout))
        } catch DBusError.timeout {
            throw IPCError.timedOut(member: member, after: SkrepkaBus.callTimeout)
        }
        guard let reply else { throw IPCError.noReply(member: member) }
        guard reply.messageType != .error else {
            throw IPCError.busError(member: member, name: reply.errorName ?? "", detail: reply.errorDetail)
        }
    }

    /// Why the unit would not start, in words that say what to do.
    static func reason(forFailedStart error: any Error) -> String {
        guard case .busError(_, let name, let detail) = error as? IPCError else {
            return "skrepkad could not be started: \(error)"
        }
        switch name {
        case "org.freedesktop.systemd1.NoSuchUnit":
            return """
                skrepkad is not installed for this user, so it cannot be started. \
                Install Skrepka again, and it will be.
                """
        case "org.freedesktop.DBus.Error.ServiceUnknown":
            return """
                This session has no systemd user manager to start skrepkad with. \
                Start it yourself with: skrepkad &
                """
        default:
            return "skrepkad could not be started: \(detail.isEmpty ? name : detail)"
        }
    }
}
