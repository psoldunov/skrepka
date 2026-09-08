import DBUS
import Foundation
import SkrepkaIPC

/// Whether this machine's clock has been set by a time server.
///
/// ## Why a clipboard manager asks
///
/// The merge model tolerates clock skew everywhere except one place, and that
/// place is the pin. `LWWRegister.merged(with:)` takes the later timestamp, so
/// a machine an hour fast wins every pin argument it has: its pin survives each
/// later unpin from the other device, and the item re-pins itself for ever. The
/// transport already refuses metadata more than `SyncLimits.maximumClockSkew`
/// into the future — see `InboundClock` — which turns the livelock into
/// something less bad and still baffling: a peer whose clippings silently stop
/// arriving.
///
/// A machine that has never run NTP is the case that produces both, and it is
/// exactly the case an embedded box, a fresh container or a laptop with a dead
/// RTC lands in. One line of `skrepka doctor` output turns it from a bug nobody
/// can diagnose into a thing to go and fix.
///
/// ## What this does not do
///
/// It does not measure the offset against a *peer*, which is what the phase
/// plan's risk note asks for and what would be strictly better. Skrepka's wire
/// protocol carries no timestamp in `hello`, so there is nothing to compare a
/// peer's clock against without a protocol change, and inventing a field that
/// is always nil would read as "no skew" when it means "never measured". This
/// answers the local half of the question honestly instead.
///
/// Confirmed against the `org.freedesktop.timedate1` interface definition
/// systemd installs at `/usr/share/dbus-1/interfaces/org.freedesktop.timedate1.xml`:
/// `NTPSynchronized` is a read-only `b`.
public enum ClockCheck {
    static let busName = "org.freedesktop.timedate1"
    static let objectPath = "/org/freedesktop/timedate1"
    static let interfaceName = "org.freedesktop.timedate1"
    static let synchronisedProperty = "NTPSynchronized"

    /// How long `timedate1` gets to answer before it is treated as absent.
    ///
    /// Two seconds, and the same two seconds as ``AvahiDiscovery/probeTimeout``
    /// because it is the same shape of call: a property read over a Unix socket
    /// from a daemon on this machine, answered at once or not at all.
    ///
    /// It exists because the connection is **shared and serial**. `DaemonService`
    /// awaits ``run(over:)`` on the same ``SkrepkaIPC/BusSession`` it makes every
    /// other call on, so a `timedate1` that accepts the call and never replies
    /// does not merely delay one diagnostics line — it holds up every method
    /// that comes after it. `DBusClient` applies no deadline of its own when
    /// none is given.
    static let replyTimeout: Duration = .seconds(2)

    /// What the check found.
    ///
    /// Three answers rather than a `Bool`, because "systemd is not running here"
    /// is a real state — a container, a distribution without it — and reporting
    /// that as "the clock is wrong" would send a user chasing a problem they do
    /// not have.
    public enum Finding: Sendable, Hashable {
        case synchronised
        case notSynchronised
        /// `timedate1` could not be reached, so nothing is known either way.
        case unknown(reason: String)

        /// The line for `skrepka doctor`, or nil when there is nothing to say.
        public var problem: String? {
            switch self {
            case .synchronised, .unknown:
                nil
            case .notSynchronised:
                """
                This machine's clock has not been set by a time server. Pins may fail to \
                propagate, and a peer may silently refuse clippings from here. Turn on time \
                synchronisation: `sudo timedatectl set-ntp true`.
                """
            }
        }
    }

    /// Reads `NTPSynchronized` from `timedate1` on the system bus.
    ///
    /// Answers ``Finding/unknown(reason:)`` for every failure rather than
    /// throwing. Nothing a caller could do with a typed error differs from what
    /// it does with "could not tell", and a diagnostics read that can fail the
    /// whole report is worse than one that reports less.
    public static func run(over session: BusSession) async -> Finding {
        do {
            let connection = try await session.connection()
            let request = DBusRequest.createMethodCall(
                destination: busName,
                path: objectPath,
                interface: "org.freedesktop.DBus.Properties",
                method: "Get",
                body: [.string(interfaceName), .string(synchronisedProperty)]
            )
            let answer = try await connection.send(
                request, timeoutNanoseconds: replyTimeout.wholeNanoseconds)
            guard let reply = answer, reply.messageType != .error else {
                return .unknown(reason: "timedate1 is not available on this system")
            }
            guard case .variant(let variant) = reply.body.first,
                case .boolean(let synchronised) = variant.value
            else {
                return .unknown(reason: "timedate1 answered something unreadable")
            }
            return synchronised ? .synchronised : .notSynchronised
        } catch DBusError.timeout {
            // Told apart from the catch below on purpose. `DBusError.timeout`
            // prints as the bare word "timeout", which in a `skrepka doctor`
            // line is a sentence with no subject — and "timedate1 did not
            // answer" is a different finding from "timedate1 is not here",
            // which is the whole reason ``Finding`` carries a reason at all.
            return .unknown(
                reason: "timedate1 did not answer within \(replyTimeout.components.seconds)s")
        } catch {
            return .unknown(reason: String(describing: error))
        }
    }
}
