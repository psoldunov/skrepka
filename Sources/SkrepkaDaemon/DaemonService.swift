import DBUS
import Foundation
import Logging
import SkrepkaIPC
import SkrepkaSync

/// Exports ``SkrepkaIPC/SkrepkaInterface`` on the session bus and routes it to
/// the daemon.
///
/// **This is not optional and it is not deferrable**, whatever it looks like
/// while the CLI is the only client. It is how the Phase 8 GNOME Shell
/// extension talks to the daemon, and designing it now is what stops an
/// interface being retrofitted around a JavaScript client written later — one
/// that ships through a review queue and cannot be changed in step with the
/// daemon.
///
/// Every method here is thin on purpose: unpack the D-Bus arguments, call one
/// method on ``Daemon``, encode the document. Nothing decides anything. A
/// decision that lived here would be one the CLI and the extension could reach
/// and the daemon's own tests could not.
public actor DaemonService {
    /// What the bus answers when a call names something this build has no
    /// meaning for.
    static let unknownMethodError = "org.freedesktop.DBus.Error.UnknownMethod"
    /// What it answers when a caller passed the wrong shape of argument.
    static let invalidArgumentsError = "org.freedesktop.DBus.Error.InvalidArgs"
    /// What it answers when the daemon could not do the thing at all — as
    /// opposed to did it and it did not work, which is an `ActionDocument` with
    /// `ok: false`.
    static let failedError = "org.freedesktop.DBus.Error.Failed"

    private let daemon: Daemon
    private let session: BusSession
    private let logger: Logger
    private var server: DBusObjectServer?
    private var historyTask: Task<Void, Never>?
    private var pairingTask: Task<Void, Never>?

    /// The daemon, for the method table in `DaemonService+Methods.swift`.
    ///
    /// `nonisolated` because it is an immutable `let` to an actor: the handlers
    /// capture it and hop onto the daemon themselves, which is what keeps a
    /// long-running call — `OpenPairing`, which waits for a listener to bind —
    /// from holding this actor while it runs.
    nonisolated var daemonReference: Daemon { daemon }

    /// - Parameter session: the session bus this exports on, **already owning**
    ///   ``SkrepkaIPC/SkrepkaInterface/busName``. ``DaemonRunner`` opens it and
    ///   claims the name with ``BusNameClaim`` before the daemon is built, so
    ///   that a second `skrepkad` loses the race before it opens the store.
    ///   Whoever opened the session closes it; ``stop()`` deliberately does not.
    public init(
        daemon: Daemon,
        session: BusSession,
        logger: Logger = Logger(label: "skrepka.service")
    ) {
        self.daemon = daemon
        self.session = session
        self.logger = logger
    }

    /// Exports the object on the session that already holds the name.
    ///
    /// The export comes last on purpose: a name on the bus is a promise that
    /// something behind it can answer, so the object is published only once the
    /// daemon is up. The *name* is claimed much earlier — see ``BusNameClaim``.
    public func start() async throws {
        let connection = try await session.connection()

        let server = DBusObjectServer(connection: connection, logger: logger)
        await server.export(exportedObject())
        // Every message the connection does not recognise as a reply is a call
        // for us. `DBusObjectServer` answers the ones it exports and returns
        // `UnknownMethod` for the rest, which is what a D-Bus client expects.
        await connection.setMessageHandler { [weak server] message in
            await server?.handle(message: message)
        }
        self.server = server
        startSignalPumps(on: connection)
        logger.notice("exported \(SkrepkaInterface.name) on the session bus")
    }

    /// Unexports the object and stops the signal pumps.
    ///
    /// The session is left open: it is the runner's, opened before this existed
    /// so the name could be claimed first, and closing it from here would drop
    /// the connection out from under a caller that has not finished with it.
    /// The runner closes it last, after the daemon has stopped.
    public func stop() async {
        historyTask?.cancel()
        historyTask = nil
        pairingTask?.cancel()
        pairingTask = nil
        await server?.unexport(path: SkrepkaInterface.objectPath)
        server = nil
    }

    /// Turns the daemon's change streams into bus signals.
    ///
    /// Two pumps rather than one, because the two signals mean different things
    /// to a subscriber and a client may want only the first — a GNOME menu
    /// redraws on history and does not care about pairing.
    private func startSignalPumps(on connection: DBusClient.Connection) {
        historyTask = Task { [weak self] in
            guard let self else { return }
            for await _ in await self.daemon.historyChanges() {
                await self.emit(SkrepkaInterface.Signal.historyChanged, body: [], on: connection)
            }
        }
        pairingTask = Task { [weak self] in
            guard let self else { return }
            for await proposal in await self.daemon.pairingProposals() {
                guard let json = try? SkrepkaDocumentCoding.encode(proposal) else { continue }
                await self.emit(
                    SkrepkaInterface.Signal.pairingRequested,
                    body: [.string(json)],
                    on: connection
                )
            }
        }
    }

    private func emit(
        _ member: String,
        body: [DBusValue],
        on connection: DBusClient.Connection
    ) async {
        let signal = DBusRequest.createSignal(
            path: SkrepkaInterface.objectPath,
            interface: SkrepkaInterface.name,
            name: member,
            body: body
        )
        do {
            _ = try await connection.send.send(signal)
        } catch {
            // Logged and dropped. A signal nobody is subscribed to is the
            // ordinary case, and a broadcast that failed must not take the
            // daemon down — the state it was announcing is still readable by
            // calling the matching method.
            logger.debug(
                "could not emit \(member)",
                metadata: ["error": .string(String(describing: error))]
            )
        }
    }
}
