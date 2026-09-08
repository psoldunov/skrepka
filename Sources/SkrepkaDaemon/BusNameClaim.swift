import DBUS
import Foundation
import SkrepkaIPC

/// Claims a well-known name on a bus, and nothing else.
///
/// Split out of ``DaemonService`` because the claim has to happen **before**
/// the daemon exists. `Daemon.init` opens the SQLite store — which installs the
/// schema, a write — so a second `skrepkad` that claimed the name from inside
/// the service had already touched the database file of the first one before it
/// discovered it had lost. A claim needs a bus connection and nothing else, so
/// ``DaemonRunner`` does this first and constructs everything afterwards.
///
/// An enum with static members rather than a type to instantiate: there is no
/// state here. Owning the name is the *connection's* property, and the
/// connection belongs to the ``SkrepkaIPC/BusSession`` the caller opened and
/// keeps open — dropping that session drops the name.
enum BusNameClaim {
    /// `DBUS_NAME_FLAG_DO_NOT_QUEUE`, from the D-Bus specification's
    /// `RequestName` flags.
    ///
    /// Set because queueing is exactly wrong here: a second `skrepkad` started
    /// against the same session must fail loudly rather than sit invisibly
    /// behind the first, waiting to take over a bus name if it ever exits. Two
    /// daemons on one clipboard is a duplicated history and two records on the
    /// network.
    static let doNotQueue: UInt32 = 4

    /// `DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER`. Every other reply code —
    /// `IN_QUEUE`, `EXISTS`, `ALREADY_OWNER` — means somebody else answers for
    /// this name, or this process asked twice.
    static let becamePrimaryOwner: UInt32 = 1

    /// Opens `session` if it is not open yet and claims `name` on it.
    ///
    /// Throws rather than warning when the name is taken. A daemon that runs
    /// with no interface is a daemon `skrepka` cannot talk to, and the systemd
    /// unit restarting it is a better outcome than a silent one nobody can
    /// reach.
    static func claim(_ name: String, over session: BusSession) async throws {
        try await claim(name, on: try await session.connection())
    }

    static func claim(_ name: String, on connection: DBusClient.Connection) async throws {
        let reply = try await connection.send(
            DBusRequest.createMethodCall(
                destination: "org.freedesktop.DBus",
                path: "/org/freedesktop/DBus",
                interface: "org.freedesktop.DBus",
                method: "RequestName",
                body: [.string(name), .uint32(doNotQueue)]
            )
        )
        guard let reply, reply.messageType != .error else {
            throw ServiceError.cannotClaimName(reason: "the bus refused RequestName")
        }
        guard case .uint32(let result) = reply.body.first else {
            throw ServiceError.cannotClaimName(reason: "the bus answered RequestName unreadably")
        }
        try verify(replyCode: result)
    }

    /// Turns a `RequestName` reply code into the error a user should read.
    ///
    /// Separate from ``claim(_:on:)`` so it can be tested: a `DBusMessage` has
    /// no public initialiser, so a reply cannot be fabricated, and the one
    /// decision worth asserting is which code means "somebody else owns it".
    static func verify(replyCode: UInt32) throws {
        guard replyCode == becamePrimaryOwner else { throw ServiceError.nameAlreadyOwned }
    }
}
