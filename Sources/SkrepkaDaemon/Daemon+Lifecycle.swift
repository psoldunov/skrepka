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
        try await startClipboard()
        guard options.syncEnabled else {
            logger.notice("sync is off; watching the clipboard only")
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

        // Everything, because this is the one teardown that owns all three:
        // both accept loops and every connection still being answered.
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
        for link in links.values { await link.stop() }
        links = [:]
        progress = [:]
        sighted = [:]

        await syncServer?.stop()
        await pairingServer?.stop()
        syncServer = nil
        pairingServer = nil
        // Stops browsing and withdraws the record, but leaves the connection
        // open — `systemBus` is the daemon's, shared with `ClockCheck`, and
        // closing it from here would take a second user's connection away.
        await discovery?.stopEverything()
        discovery = nil
        await systemBus.stop()
        isPublished = false

        // Callback form rather than the blocking one: `shutdownGracefully()`
        // parks a cooperative-pool thread until the loops drain, and draining
        // them resumes continuations that need a cooperative thread to run on.
        group?.shutdownGracefully { _ in }
        group = nil
        runtime = nil

        for observer in historyObservers.values { observer.finish() }
        historyObservers = [:]
        for observer in pairingObservers.values { observer.finish() }
        pairingObservers = [:]
    }

    // MARK: - Sync

    func startSync() async throws {
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
                    protocolVersion: .current
                ),
                localCertificate: certificate
            ),
            trust: trust,
            store: store,
            group: group
        )
        self.runtime = runtime

        try await startSyncListener(runtime: runtime, port: options.port)
        await startDiscovery(runtime: runtime)
    }

    /// Everything the diagnostics document needs about the network half.
    func networkSummary() async -> (responder: String, problem: String?) {
        guard options.syncEnabled else { return ("off", "sync is turned off with --no-sync") }
        guard discovery != nil else { return ("none", responderProblem ?? "no responder is running") }
        return ("avahi", responderProblem)
    }
}
