import Foundation
import Logging
import NIOCore
import NIOPosix
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

// Turning the network half on and off while the daemon runs. Everything here
// runs inside queued lifecycle work — see `Daemon.enqueue(_:)` — because it
// stops and starts servers across several awaits, the same window bring-up and
// tear-down were queued to close.
extension Daemon {
    /// True when the daemon was started with `--no-sync`, which no setting
    /// overrides.
    var isSyncLockedOff: Bool { !options.syncEnabled }

    /// Whether this device should be on the network now.
    var isSyncWanted: Bool { !isSyncLockedOff && settings.sync.enabled }

    /// Brings sync up or takes it down to match ``isSyncWanted``.
    ///
    /// - Returns: a sentence saying what went wrong, or nil.
    func performReconcileSync() async -> String? {
        guard !isStopping else { return nil }
        if isSyncWanted {
            guard runtime == nil else { return nil }
            do {
                try await startSync()
                logger.notice("sync turned on")
                return nil
            } catch {
                logger.error(
                    "could not turn sync on",
                    metadata: ["error": .string(String(describing: error))])
                // Whatever `startSync()` got as far as binding is torn down, so
                // a half-started stack is not left advertising nothing.
                await stopSyncStack(closingSystemBus: false)
                return "sync could not start: \(error)"
            }
        }
        guard runtime != nil else { return nil }
        await stopSyncStack(closingSystemBus: false)
        logger.notice("sync turned off")
        return nil
    }

    /// Takes the network half down: links, listeners, the pairing window and
    /// the advertisement. The clipboard and the history are untouched.
    ///
    /// `closingSystemBus` is true only from ``performStop()``. Turning sync off
    /// at runtime leaves the system-bus connection open because `ClockCheck`
    /// shares it, and turning sync back on opens discovery on the same one.
    func stopSyncStack(closingSystemBus: Bool) async {
        advanceSyncGeneration()
        stopSyncTasks()
        for link in links.values { await link.stop() }
        links = [:]
        progress = [:]
        sighted = [:]

        await syncServer?.stop()
        await pairingServer?.stop()
        syncServer = nil
        pairingServer = nil
        // Stops browsing and withdraws the record, but leaves the connection
        // open — `systemBus` is the daemon's, shared with `ClockCheck`.
        await discovery?.stopEverything()
        discovery = nil
        if closingSystemBus { await systemBus.stop() }
        isPublished = false

        // Callback form rather than the blocking one: `shutdownGracefully()`
        // parks a cooperative-pool thread until the loops drain, and draining
        // them resumes continuations that need a cooperative thread to run on.
        group?.shutdownGracefully { _ in }
        group = nil
        runtime = nil
    }

    /// Every task the network half owns: both accept loops, every connection
    /// still being answered, the pairing window and anything waiting on it.
    private func stopSyncTasks() {
        syncAcceptTask?.cancel()
        syncAcceptTask = nil
        pairingAcceptTask?.cancel()
        pairingAcceptTask = nil
        for task in connectionTasks.values { task.cancel() }
        connectionTasks = [:]
        pairingExpiry?.cancel()
        pairingExpiry = nil
        pairingWindowEnds = nil
        for pairing in pending.values { pairing.expire() }
        pending = [:]

        browseTask?.cancel()
        browseTask = nil
        advertisementFailureTask?.cancel()
        advertisementFailureTask = nil
    }
}
