import Foundation
import NIOCore
import NIOPosix
import SkrepkaCore
import SkrepkaSync
import os

/// Bringing sync up and taking it down, and the queue that keeps the two from
/// overlapping.
///
/// Split from `SyncCoordinator.swift`, which is now the type, its state and the
/// switch that drives this. The rest of the coordinator is in
/// `SyncCoordinator+Serving.swift`, `+Discovery.swift`, `+Pairing.swift`,
/// `+LivePush.swift` and `+Rows.swift`.
extension SyncCoordinator {

    /// Brings sync up, or does nothing when the user has it switched off.
    ///
    /// Every failure lands in ``errorMessage`` rather than throwing: this is
    /// called from `AppCoordinator.start()`, where there is nobody to catch it,
    /// and a Mac that cannot open a listening socket should still be a
    /// clipboard manager.
    func start() async {
        guard isEnabled else { return }
        await enqueueLifecycle { [weak self] in await self?.performStart() }.value
    }

    func stop() async {
        await enqueueLifecycle { [weak self] in await self?.performStop() }.value
    }

    /// Runs `work` after every change to the running stack already queued.
    ///
    /// **One mechanism for a whole class of bug rather than a guard per site.**
    /// Bringing sync up, tearing it down, restarting the pinned listener and
    /// opening or closing the pairing window all take several awaits, all mutate
    /// the same handful of properties, and this type is `@MainActor` — which
    /// serialises statements, not *operations*. Two of them interleaved at an
    /// await left a listener bound with nobody holding it, a second event-loop
    /// group nothing could reach, or the switch reading on with nothing running.
    ///
    /// Checking a generation counter after each await would find those; keeping
    /// them from overlapping stops them happening, and does not have to be
    /// remembered again by whoever adds the next `await`. That is the whole
    /// reason for the shape.
    ///
    /// Callers that must not re-enter the queue — ``performStop()`` closing the
    /// pairing listener, say — call the `perform` half directly. Awaiting the
    /// returned task from inside queued work would wait on the queue that is
    /// waiting on it.
    @discardableResult
    func enqueueLifecycle(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = lifecycleTail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        lifecycleTail = task
        return task
    }

    /// Runs `work` after every per-peer setting write already queued.
    ///
    /// The same shape as ``enqueueLifecycle(_:)`` and for the same reason, on a
    /// chain of its own. A switch in the Sync pane is a `Binding` setter, which
    /// is synchronous, so writing a setting means starting a task — and two
    /// bare tasks are unordered. Two quick flips of one peer's live-push switch
    /// then reach the store in whichever order they happen to run, and the
    /// persisted answer is whichever landed last rather than whichever the user
    /// chose last. For this setting that decides whether clipboard content keeps
    /// flowing to a peer the user has just switched off.
    ///
    /// Nothing awaits the returned task: the caller is a `Binding` setter with
    /// nowhere to await from, and the ordering is what it needed rather than the
    /// completion.
    func enqueueSetting(_ work: @escaping @MainActor () async -> Void) {
        let previous = settingTail
        settingTail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    func performStart() async {
        guard runtime == nil else { return }
        // The origin with the message. Leaving a stale one behind would have the
        // first `.ready` of this run decline to clear its own message, because
        // the slot would still be marked as somebody else's.
        errorMessage = nil
        messageOrigin = .elsewhere
        isLocalNetworkDenied = false
        do {
            try await bringUp()
        } catch {
            showMessage(SyncFailureText.describe(error), from: .elsewhere)
            SkrepkaLog.sync.error(
                "Sync could not start: \(String(describing: error), privacy: .public)"
            )
            await performStop()
        }
    }

    func performStop() async {
        // First, before any await. Everything below suspends, and until
        // `runtime` is nilled at the end a re-entrant `reconcileLinks()` would
        // read a running coordinator and rebuild the links this is removing.
        isTearingDown = true
        defer { isTearingDown = false }

        // Anyone parked on a sheet is answered "no" before the machinery that
        // would have carried a "yes" goes away. A continuation that is never
        // resumed is a task suspended for the life of the process.
        answerPairing(false)
        pendingPairing = nil
        isPairingInFlight = false

        // The publish retry with the rest: one still sleeping would wake into a
        // coordinator that has switched sync off and try to advertise it.
        cancelPublishRetry()
        publishAttempts = 0

        acceptTask?.cancel()
        pairingAcceptTask?.cancel()
        browseTask?.cancel()
        acceptTask = nil
        pairingAcceptTask = nil
        browseTask = nil

        for link in links.values {
            await link.stop()
        }
        links.removeAll()

        // The `perform` half, not the queued wrapper: this is already running
        // inside the lifecycle queue, and enqueuing behind itself would wait
        // forever. See ``enqueueLifecycle(_:)``.
        await performStopPairingListener()
        await syncServer?.stop()
        syncServer = nil
        if let discovery {
            await discovery.stopAdvertising()
            await discovery.stopBrowsing()
        }
        discovery = nil
        // Callback form rather than `syncShutdownGracefully()`: the blocking one
        // parks a cooperative-pool thread until the loops drain, and draining
        // them resumes continuations that need a cooperative thread to run on.
        group?.shutdownGracefully { _ in }
        group = nil
        runtime = nil
        localDeviceID = nil
        sighted.removeAll()
        progress.removeAll()
        isAcceptingPairing = false
        isPublished = false
        isLocalNetworkDenied = false
        // Discovery's message goes with the discovery that wrote it. A failure
        // from anywhere else is the user's to read after the switch went off.
        clearMessage(from: .discovery)
        refreshRows()
    }

    /// Brings sync up as far as it can go without asking macOS for anything.
    ///
    /// **It deliberately stops short of publishing this device or dialling any
    /// peer.** Both of those need the Local Network privilege, and so does
    /// resolving a peer's address; browsing needs it too. While that privilege
    /// is undetermined macOS denies each such operation *and* raises its own
    /// alert about it — Apple's TN3179, *Understanding local network privacy*,
    /// says the denial comes first and does not wait for the user's answer. Four
    /// of them fired one after another is therefore four chances at an alert and
    /// a bring-up that has already failed by the time the user reads the first,
    /// which is what made switching sync on turn itself back off again.
    ///
    /// So exactly one operation goes first, and it is the browse: it is the only
    /// one of the four that *waits* rather than failing, and `NWBrowser` returns
    /// to `.ready` by itself the moment access is granted. ``performPublish()``
    /// hangs off that, so answering the alert finishes the job with nothing else
    /// to press.
    ///
    /// Listening is not on the list. TN3179's table of local network operations
    /// puts "listening for and accepting incoming TCP connections" at *no*, so
    /// both listeners bind before any of this and neither one can prompt.
    func bringUp() async throws {
        let certificate = try await trust.localIdentity()
        localDeviceID = certificate.deviceID
        // The store stamps new rows with this and writes tombstones only once it
        // has one, so it has to land before anything is captured or offered.
        store.localDeviceID = certificate.deviceID

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        let runtime = SyncRuntime(
            certificate: certificate,
            pairing: PairingSession(
                localIdentity: PeerIdentity(
                    deviceID: certificate.deviceID,
                    deviceName: displayName,
                    platform: .macos,
                    protocolVersion: .current
                ),
                localCertificate: certificate
            ),
            trust: trust,
            store: store,
            group: group
        )
        self.runtime = runtime

        try await reloadPairedPeers()
        try await startSyncListener(runtime: runtime)
        try await startBrowsing()
    }

    /// Re-reads the paired set and the live-push choices that go with it.
    func reloadPairedPeers() async throws {
        let peers = try await trust.pairedPeers()
        paired = Dictionary(uniqueKeysWithValues: peers.map { ($0.deviceID, $0) })
        var choices: [SyncDeviceID: LivePushChoice] = [:]
        for peer in peers {
            choices[peer.deviceID] = try await trust.livePushChoice(for: peer.deviceID)
        }
        livePushChoices = choices
        refreshRows()
    }

    /// The name this device publishes, which is the one the user set in Sharing.
    static func deviceName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
    }
}
