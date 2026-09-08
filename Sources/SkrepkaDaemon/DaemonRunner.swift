import Foundation
import Logging
import SkrepkaIPC

#if canImport(Glibc)
    import Glibc
#endif

/// Runs the daemon until something asks it to stop.
///
/// Split from `main.swift` because `swift test` cannot import an executable
/// target, and the signal handling below is the part most worth a test: a
/// daemon that does not shut down cleanly leaves a half-written database and a
/// bus name nobody else can claim.
public enum DaemonRunner {
    /// Exit codes, which the systemd unit's `Restart=` policy reads.
    public enum Exit {
        public static let ok: Int32 = 0
        /// The daemon could not start at all. A restart will not help until
        /// whatever it is has been fixed, which is why the unit pairs
        /// `Restart=on-failure` with a start-limit burst.
        public static let cannotStart: Int32 = 1
        /// The command line was wrong.
        public static let usage: Int32 = 2
    }

    /// Builds everything, runs it, and returns once a signal has arrived.
    ///
    /// **The bus name is claimed before anything else is built**, and that
    /// order is the whole point of this function's shape. Constructing `Daemon`
    /// opens the SQLite store, which installs the schema — a write — so a
    /// second `skrepkad` that claimed the name any later than this would have
    /// written to the first one's database file before it found out it had
    /// lost. A claim needs a bus connection and nothing else, so it goes first
    /// and everything else is built behind it.
    public static func run(_ options: DaemonOptions) async -> Int32 {
        var logger = Logger(label: "skrepka.daemon")
        // `DaemonOptions` refuses a level it cannot spell, so the fallback is
        // only for a `DaemonOptions` built in code rather than parsed.
        logger.logLevel = Logger.Level(rawValue: options.logLevel) ?? .info

        // Before anything is started. A SIGTERM arriving during a slow start —
        // systemd's `TimeoutStartSec`, or a `systemctl stop` typed while the
        // store is opening — would otherwise meet the default disposition and
        // kill the process outright.
        if !SignalWatch.installHandlers() {
            logger.warning("could not install the signal handlers; shutdown will not be clean")
        }

        // The session is opened here rather than inside `DaemonService`,
        // because the claim has to precede the daemon and the export has to
        // follow it: one session, held by whoever spans both.
        return await run(options, over: BusSession(bus: .session), logger: logger)
    }

    /// ``run(_:)`` without the signal handlers, over a session a caller
    /// supplies.
    ///
    /// The seam exists for one test: pointed at a socket nothing is listening
    /// on, this returns ``Exit/cannotStart`` having opened no store, which is
    /// the ordering the type comment above is about. Installing process-wide
    /// signal handlers is left to the public entry point, because a test
    /// process that stops answering `SIGTERM` is a test process CI has to kill.
    static func run(
        _ options: DaemonOptions,
        over session: BusSession,
        logger: Logger = Logger(label: "skrepka.daemon")
    ) async -> Int32 {
        do {
            try await BusNameClaim.claim(SkrepkaInterface.busName, over: session)
        } catch {
            // `ServiceError.nameAlreadyOwned` is the one a user is most likely
            // to meet, and it says how to stop the other daemon.
            logger.critical("could not start: \(Self.describe(error))")
            await session.stop()
            return Exit.cannotStart
        }

        let code = await serve(options, session: session, logger: logger)
        await session.stop()
        return code
    }

    /// Everything behind the name: the daemon, the exported object, and the
    /// wait for a signal.
    ///
    /// Split from ``run(_:)`` so that neither is a forty-line function with two
    /// teardown paths in it. By the time this is called the name is won, so a
    /// failure here is this machine's problem rather than a second instance.
    private static func serve(
        _ options: DaemonOptions,
        session: BusSession,
        logger: Logger
    ) async -> Int32 {
        let daemon: Daemon
        do {
            daemon = try Daemon(options: options, logger: logger)
        } catch {
            // A failure here is the store or the device key, and the message is
            // written for whoever reads the journal after the unit failed —
            // `FileTrustStore.IdentityError` in particular says what to do
            // rather than what went wrong.
            logger.critical("could not start: \(Self.describe(error))")
            return Exit.cannotStart
        }

        let service = DaemonService(daemon: daemon, session: session, logger: logger)
        do {
            // The export is last: a name on the bus is a promise that something
            // behind it can answer.
            try await daemon.start()
            try await service.start()
        } catch {
            logger.critical("could not start: \(Self.describe(error))")
            await service.stop()
            await daemon.stop()
            return Exit.cannotStart
        }

        logger.notice(
            "skrepkad \(DaemonVersion.current) is running",
            metadata: ["store": .string(options.storeURL().path)]
        )
        await SignalWatch.waitForTermination()
        logger.notice("stopping")
        await service.stop()
        await daemon.stop()
        return Exit.ok
    }

    /// The message a user should see.
    ///
    /// Every error type the start path can throw is `CustomStringConvertible`
    /// and carries a sentence written for a person — that is the repo's rule
    /// about errors reaching a user, and the journal is where a user reads a
    /// daemon's errors. `String(describing:)` prints exactly that `description`
    /// for such a type, so there is nothing to branch on: a conditional cast to
    /// `CustomStringConvertible` here is one the compiler rejects as always
    /// succeeding.
    ///
    /// An error type that grows without a `description` therefore degrades to
    /// its synthesised spelling rather than to something wrong, which is the
    /// right failure for a message in a log.
    static func describe(_ error: any Error) -> String {
        String(describing: error)
    }
}
