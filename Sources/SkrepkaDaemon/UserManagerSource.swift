import SkrepkaIPC
import SkrepkaLinuxPlatform

/// Where a daemon that started without a display asks for one: the systemd
/// user manager over the session bus, or a test's stand-in.
///
/// A seam rather than a `BusSession` held directly, because the path worth
/// testing — the manager answers with a display, capture starts on it, and the
/// connection is let go — cannot be reached from a test otherwise: every test
/// daemon runs on an empty environment, which names no bus to ask.
public struct UserManagerSource: Sendable {
    /// The manager's display variables now, or nil when it could not be asked.
    let read: @Sendable () async -> [String: String]?
    /// Lets go of whatever the reads held open.
    let close: @Sendable () async -> Void

    public init(
        read: @escaping @Sendable () async -> [String: String]?,
        close: @escaping @Sendable () async -> Void
    ) {
        self.read = read
        self.close = close
    }

    /// The live manager, on the session bus `environment` names — or nil when
    /// it names none, which is every test's empty environment.
    static func sessionBus(in environment: [String: String]) -> UserManagerSource? {
        UserManagerEnvironment.busAddress(in: environment).map { address in
            let session = BusSession(bus: .session, address: address)
            return UserManagerSource(
                read: { await UserManagerEnvironment.read(over: session) },
                close: { await session.stop() }
            )
        }
    }
}
