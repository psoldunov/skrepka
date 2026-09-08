import Foundation

/// Why a call to the daemon did not produce an answer.
///
/// Named far enough apart that the CLI can print advice rather than a
/// stringified error. "Cannot reach the session bus", "the daemon is not
/// running" and "the daemon answered something this build cannot read" have
/// three different remedies, and one opaque error gives the user none of them.
public enum IPCError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The session bus could not be reached at all. Usually no
    /// `DBUS_SESSION_BUS_ADDRESS` and no `XDG_RUNTIME_DIR`, which is what an
    /// `ssh` session without a lingering user session looks like.
    case daemonUnavailable(reason: String)

    /// The bus answered with an error reply.
    ///
    /// `org.freedesktop.DBus.Error.ServiceUnknown` is the one worth
    /// recognising: it means nothing owns ``SkrepkaInterface/busName``, which
    /// is the daemon not running rather than anything being broken.
    case busError(member: String, name: String, detail: String)

    /// The call completed with no reply message, which the transport should not
    /// produce for a method call that did not set `noReplyExpected`.
    case noReply(member: String)

    /// A reply arrived with a body this build did not expect — the wrong D-Bus
    /// type in the first slot.
    case unexpectedReply(member: String)

    /// The daemon owns the bus name and did not answer inside
    /// ``SkrepkaBus/callTimeout``.
    ///
    /// Deliberately not ``daemonUnavailable(reason:)``: something *is* there
    /// answering for the name, so "enable the unit" is the wrong advice.
    case timedOut(member: String, after: Duration)

    /// Whether this is "the daemon is not running" rather than a fault.
    public var isDaemonNotRunning: Bool {
        guard case .busError(_, let name, _) = self else { return false }
        return name == "org.freedesktop.DBus.Error.ServiceUnknown"
            || name == "org.freedesktop.DBus.Error.NameHasNoOwner"
    }

    public var description: String {
        switch self {
        case .daemonUnavailable(let reason):
            "cannot reach the session bus: \(reason)"
        case .busError(let member, let name, let detail) where !detail.isEmpty:
            "\(member) failed: \(detail) (\(name))"
        case .busError(let member, let name, _):
            "\(member) failed: \(name)"
        case .noReply(let member):
            "\(member) produced no reply"
        case .unexpectedReply(let member):
            "\(member) answered something this build cannot read"
        case .timedOut(let member, let after):
            "\(member) did not answer within \(after.components.seconds) seconds"
        }
    }

    /// What to tell the user to do about it.
    public var remedy: String? {
        if isDaemonNotRunning {
            return "Start it with: systemctl --user start skrepkad"
        }
        switch self {
        case .daemonUnavailable:
            return """
                Skrepka talks to its daemon over the session bus, which needs a logged-in \
                desktop session. Over SSH, try: systemctl --user enable --now skrepkad
                """
        case .timedOut:
            return """
                The daemon holds the bus name but did not answer. It may be busy \
                syncing with a peer; try again, and if it keeps happening: \
                systemctl --user status skrepkad
                """
        case .busError, .noReply, .unexpectedReply:
            return nil
        }
    }
}
