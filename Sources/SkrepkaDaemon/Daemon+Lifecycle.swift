import Foundation
import Logging
import NIOCore
import NIOPosix
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// Brings everything up, in the order the pieces depend on each other.
    ///
    /// **The clipboard comes first and sync second, and the order is
    /// load-bearing.** A machine whose compositor offers no data-control
    /// protocol should still sync — a Linux box on a shelf with a paired Mac is
    /// a useful thing — so a clipboard that will not start is reported and
    /// stepped over rather than fatal. The reverse is not true: sync that
    /// cannot start leaves a working local clipboard manager, which is the
    /// product Phase 4 already shipped.
    ///
    /// Queued, for the reason ``Daemon/openPairing(for:)`` is. This suspends
    /// inside ``startClipboard()`` and again inside ``startSync()``, and
    /// ``stop()`` is queued — so a shutdown that began during either
    /// suspension ran ``performStop()`` to completion, clearing the runtime and
    /// stopping the listeners, and then bring-up resumed and started discovery
    /// *after* `stop()` had returned. The daemon was left holding a listener
    /// and a published record that nothing would ever tear down. Both halves on
    /// one queue makes the order total whichever arrives first, and it is the
    /// answer rather than re-reading ``isStopping`` after each `await`: a
    /// re-check has to be remembered at every suspension point added from now
    /// on, and the queue cannot be forgotten.
    public func start() async throws {
        try await enqueueAnswering { try await $0.performStart() }.value
    }

    func performStart() async throws {
        // Not a re-check after a suspension: this is the first statement, and
        // it means a `stop()` that was queued ahead of this one has already
        // finished. Bringing a stopped daemon up behind its own shutdown is
        // the other half of the bug the queue closes.
        guard !isStopping else { return }
        await startFileCache()
        startRetentionSweep()
        try await startClipboard()
        guard isSyncWanted else {
            logger.notice(
                "sync is off; watching the clipboard only",
                metadata: ["reason": .string(isSyncLockedOff ? "--no-sync" : "settings")])
            return
        }
        try await startSync()
    }

    /// Stops everything and waits for it. Idempotent.
    public func stop() async {
        isStopping = true
        await enqueue { await $0.performStop() }.value
    }

    func performStop() async {
        captureTask?.cancel()
        captureTask = nil
        await watcher?.stop()
        watcher = nil
        await clipboard?.stop()
        clipboard = nil

        retentionSweepTask?.cancel()
        retentionSweepTask = nil
        await stopSyncStack(closingSystemBus: true)

        for observer in historyObservers.values { observer.finish() }
        historyObservers = [:]
        for observer in pairingObservers.values { observer.finish() }
        pairingObservers = [:]
    }

    // MARK: - Sync

    func startSync() async throws {
        advanceSyncGeneration()
        let certificate = try await trust.localIdentity()
        await store.setLocalDeviceID(certificate.deviceID)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let runtime = SyncRuntime(
            certificate: certificate,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: certificate.deviceID,
                    deviceName: displayName,
                    platform: .linux,
                    protocolVersion: .current,
                    // Without it a peer withholds file bundles from this one,
                    // and a file copied there pastes here as its names.
                    capabilities: SyncCapability.local
                ),
                localCertificate: certificate
            ),
            trust: trust,
            store: store,
            group: group,
            fileSync: fileSync,
            transfers: transfers
        )
        self.runtime = runtime

        try await startSyncListener(runtime: runtime, port: options.port)
        await startDiscovery(runtime: runtime)
    }

    /// Everything the diagnostics document needs about the network half.
    func networkSummary() async -> (responder: String, problem: String?) {
        guard !isSyncLockedOff else { return ("off", "sync is turned off with --no-sync") }
        guard settings.sync.enabled else { return ("off", "sync is turned off in the settings") }
        guard discovery != nil else { return ("none", responderProblem ?? "no responder is running") }
        return (await responderLabel(), responderProblem)
    }
}
