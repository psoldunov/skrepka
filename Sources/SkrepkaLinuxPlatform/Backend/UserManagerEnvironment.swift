import DBUS
import Foundation
import SkrepkaIPC

/// The display variables the systemd user manager holds *now*, for a daemon
/// that started before the desktop exported them.
///
/// ## Why the daemon asks the manager
///
/// `skrepkad.service` hangs off `default.target`, which the user manager
/// reaches as soon as it starts — on Plasma, before KWin has run and before
/// `startplasma` has pushed `WAYLAND_DISPLAY` into the manager with
/// `UpdateActivationEnvironment`. A unit started in that window gets an
/// environment with no display in it, and a process's environment is a
/// snapshot: nothing the manager learns afterwards reaches it. So a daemon
/// that only re-read its own environment would watch nothing until the next
/// `systemctl --user restart skrepkad`, however long the session lasted.
///
/// The manager publishes what it would give a unit started now as the
/// `Environment` property (`as`, `KEY=VALUE`) of
/// `org.freedesktop.systemd1.Manager`, on the session bus — confirmed with
/// `busctl --user introspect org.freedesktop.systemd1 /org/freedesktop/systemd1`
/// against systemd 261. The property emits no change signal, so it is polled.
public enum UserManagerEnvironment {
    static let busName = "org.freedesktop.systemd1"
    static let objectPath = "/org/freedesktop/systemd1"
    static let interfaceName = "org.freedesktop.systemd1.Manager"
    static let propertyName = "Environment"

    /// How long the manager gets to answer. The same two seconds
    /// `ClockCheck.replyTimeout` gives `timedate1`, for the same reason: a
    /// property read from a local service answers at once or not at all.
    static let replyTimeout: Duration = .seconds(2)

    /// The variables that say which desktop session to watch and how to reach
    /// it. Nothing else is taken from the manager: the rest of its environment
    /// is the user's business, not the capture backend's.
    public static let displayKeys: Set<String> = [
        "WAYLAND_DISPLAY", "DISPLAY", "XAUTHORITY", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP",
    ]

    /// Whether `environment` names a display at all.
    public static func hasDisplay(_ environment: [String: String]) -> Bool {
        ["WAYLAND_DISPLAY", "DISPLAY"].contains { environment[$0]?.isEmpty == false }
    }

    /// `environment` with the manager's display variables filled in — or
    /// `environment` unchanged when it already names a display.
    ///
    /// A process that was started with a display keeps it. That is the daemon
    /// run from a terminal inside a nested compositor, and the manager's idea
    /// of the display is the outer session's, which is the wrong one to watch.
    public static func filling(
        _ environment: [String: String], from manager: [String: String]
    ) -> [String: String] {
        guard !hasDisplay(environment), hasDisplay(manager) else { return environment }
        return environment.merging(manager.filter { displayKeys.contains($0.key) }) { _, new in new }
    }

    /// The display variables in a list of `KEY=VALUE` assignments. An entry
    /// with no `=`, or an empty value, is skipped rather than read as a blank
    /// display name.
    public static func parse(_ assignments: [String]) -> [String: String] {
        var found: [String: String] = [:]
        for assignment in assignments {
            guard let equals = assignment.firstIndex(of: "=") else { continue }
            let key = String(assignment[..<equals])
            let value = String(assignment[assignment.index(after: equals)...])
            guard displayKeys.contains(key), !value.isEmpty else { continue }
            found[key] = value
        }
        return found
    }

    /// The display variables in the body of a `Properties.Get` reply for
    /// `Environment`: one variant holding the `as` of assignments. Nil for any
    /// other shape, and a non-string element is skipped rather than failing
    /// the whole reply.
    ///
    /// Separate from ``read(over:)`` because the library can build a reply's
    /// body but not a received `DBusMessage`, so this half is what a test can
    /// reach.
    static func displayVariables(inReply body: [DBusValue]) -> [String: String]? {
        guard case .variant(let variant) = body.first, case .array(let values) = variant.value else {
            return nil
        }
        return parse(values.compactMap { if case .string(let text) = $0 { text } else { nil } })
    }

    /// The session bus to ask on, as `environment` names it, or nil when it
    /// names none.
    ///
    /// Read from `environment` rather than left to the library's default, so a
    /// daemon built on an empty environment — every test in this repository
    /// builds one — never reaches the bus of the machine running the tests. The
    /// `$XDG_RUNTIME_DIR/bus` fallback is where the D-Bus specification puts a
    /// session bus that systemd manages.
    public static func busAddress(in environment: [String: String]) -> String? {
        if let address = environment["DBUS_SESSION_BUS_ADDRESS"], !address.isEmpty { return address }
        guard let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty else { return nil }
        return "unix:path=\(runtime)/bus"
    }

    /// Reads the manager's display variables over `session`.
    ///
    /// Nil for every failure — no systemd, no answer, an unreadable one —
    /// because the caller does the same thing with each: keeps what it had
    /// and asks again later.
    public static func read(over session: BusSession) async -> [String: String]? {
        do {
            let connection = try await session.connection()
            let request = DBusRequest.createMethodCall(
                destination: busName,
                path: objectPath,
                interface: "org.freedesktop.DBus.Properties",
                method: "Get",
                body: [.string(interfaceName), .string(propertyName)]
            )
            let answer = try await connection.send(
                request, timeoutNanoseconds: replyTimeout.wholeNanoseconds)
            guard let reply = answer, reply.messageType != .error else { return nil }
            return displayVariables(inReply: reply.body)
        } catch {
            // Uninteresting on its own: the retry schedule asks again, and
            // the journal already says nothing is being captured. The
            // connection is dropped so that the next ask opens a fresh one
            // rather than failing on a dead one for ever.
            await session.invalidate()
            return nil
        }
    }
}
