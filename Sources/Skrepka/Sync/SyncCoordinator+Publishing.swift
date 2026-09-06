import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// Being *found* on the network: publishing this device's record, keeping it in
/// step with what the device now is, and recovering when the responder will not
/// take it.
///
/// Split from `SyncCoordinator+Discovery.swift`, which browses and keeps the
/// links. The two halves meet at one point — the browse reaching
/// ``DiscoveryEvent/ready`` is what calls ``performPublish()`` — and that is the
/// Local Network permission gate `SyncCoordinator.bringUp()` describes.
///
/// The pane's one message line lives here too, because publishing is what writes
/// to it most and because the rule about *clearing* it is a rule about
/// discovery: a browse recovering must not take back a sentence some other part
/// of sync put there.
extension SyncCoordinator {
    /// Publishes this device and dials its peers.
    ///
    /// Driven by the browse reaching ``DiscoveryEvent/ready`` rather than called
    /// from ``SyncCoordinator/bringUp()``: that is the moment macOS is known to
    /// be letting this app onto the local network, and running before it would
    /// be the second and third permission prompts this split exists to remove.
    ///
    /// **Runs on every `.ready`, not only the first, and that is deliberate.**
    /// The browse sends one again after every stall it recovers from — a lid
    /// closing, a Wi-Fi network changing, the user granting access in System
    /// Settings twenty minutes later. Each of those is also a moment the
    /// registration underneath may have been withdrawn by the responder, and
    /// running only once would leave this Mac off the network with nothing
    /// noticing. ``PeerDiscovery/updateAdvertisement(_:)`` costs an actor hop
    /// and nothing else when the record is already right, and
    /// ``reconcileLinks()`` is idempotent by construction, so the repeat is
    /// cheap and it heals a lost advertisement.
    ///
    /// Queued on the lifecycle chain by its caller, so it cannot interleave with
    /// a tear-down or a listener restart.
    func performPublish() async {
        guard !isTearingDown, let runtime, let discovery, syncServer != nil else { return }
        do {
            try await discovery.updateAdvertisement(descriptor(for: runtime))
            isPublished = true
            publishAttempts = 0
            cancelPublishRetry()
            clearMessage(from: .discovery)
            reconcileLinks()
        } catch {
            handlePublishFailure(error)
        }
    }

    /// Says what happened and decides whether anything will try again.
    ///
    /// **The two failures behave nothing alike**, which is why the decision is a
    /// value in `SkrepkaSync.PublishRetryPolicy` rather than a branch here: a
    /// refused privilege is waited out, because the browse returning to `.ready`
    /// is already the retry and re-asking on a timer only re-asks a question
    /// macOS is currently answering with an alert. Anything else is a fault, and
    /// nothing else in the app would ever retry it — the browse reaches `.ready`
    /// **once** on a network that does not change, so an unretried publish
    /// failure is permanent, and it leaves the switch reading on with this Mac
    /// on nobody's list.
    ///
    /// ``isPublished`` is deliberately not cleared here. It is the permission
    /// gate — "macOS has let this app onto the network and the record went up at
    /// least once" — not a live reading of the advertisement, and clearing it
    /// would gate ``reconcileLinks()``, whose *first* loop is how an unpaired
    /// peer's link gets stopped. A device that cannot re-publish should not also
    /// stop being able to forget a peer.
    func handlePublishFailure(_ error: any Error) {
        isLocalNetworkDenied = (error as? DiscoveryError) == .localNetworkDenied
        SkrepkaLog.sync.error(
            "Could not publish this device: \(String(describing: error), privacy: .public)"
        )
        switch PublishRetryPolicy.recovery(from: error, afterAttempts: publishAttempts) {
        case .waitForAccess:
            cancelPublishRetry()
            showMessage(SyncFailureText.describe(error), from: .discovery)
        case .retry(let delay):
            publishAttempts += 1
            showMessage(SyncFailureText.describe(error), from: .discovery)
            schedulePublishRetry(after: delay)
        case .giveUp:
            cancelPublishRetry()
            showMessage(SyncFailureText.publishGaveUp, from: .discovery)
        }
    }

    /// Queues one more attempt, replacing any already waiting.
    ///
    /// The attempt goes through ``SyncCoordinator/enqueueLifecycle(_:)`` rather
    /// than running where the sleep ends, so it cannot land in the middle of a
    /// tear-down or a listener restart. `performPublish()`'s own guard is what
    /// catches a retry that outlived the thing it was retrying for.
    private func schedulePublishRetry(after delay: Duration) {
        publishRetryTask?.cancel()
        publishRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.enqueueLifecycle { [weak self] in await self?.performPublish() }
        }
    }

    func cancelPublishRetry() {
        publishRetryTask?.cancel()
        publishRetryTask = nil
    }

    /// Brings the published record back in line with what this device now is,
    /// which is how a new listening port or an opened pairing window reaches the
    /// network.
    ///
    /// Amended rather than stopped and started. Every caller here changes only
    /// the `pair=` key or nothing at all, and withdrawing the record to publish
    /// an almost identical one takes this Mac off every peer's browse list and
    /// puts it back — three times over the course of one pairing, while the user
    /// is watching the other machine's device list. ``AdvertisementChange`` is
    /// where the decision lives.
    ///
    /// Silent before ``performPublish()`` has run: there is nothing published to
    /// amend, and publishing here would jump the permission gate.
    ///
    /// **Handles its own failure rather than throwing.** It used to throw into
    /// three call sites that each did something different with it, and one of
    /// them dropped it — which mattered most in the case that is hardest to see:
    /// ``AdvertisementChange/republish`` withdraws the registration before it
    /// makes the new one, so a throw on the way back up leaves this Mac
    /// advertised nowhere while ``isPublished`` still says it is. Nothing
    /// re-published it, because the only other trigger is a `.ready` that has
    /// already been and gone. Routing it into ``handlePublishFailure(_:)``
    /// instead puts it on the same retry as a first publish that failed.
    /// `isTearingDown` as well as the rest, and it is not decoration.
    /// ``performStop()`` reaches here through `performStopPairingListener()`,
    /// which runs *before* it nils `syncServer` and `isPublished` — so without
    /// this, switching sync off could fail a republish on the way down, schedule
    /// a retry that outlives the tear-down, and leave a "could not publish"
    /// message on a pane whose switch now reads off.
    func republishAdvertisement() async {
        guard !isTearingDown, let discovery, let runtime, syncServer != nil, isPublished
        else { return }
        do {
            try await discovery.updateAdvertisement(descriptor(for: runtime))
            publishAttempts = 0
            cancelPublishRetry()
            clearMessage(from: .discovery)
        } catch {
            handlePublishFailure(error)
        }
    }

    // MARK: - The pane's one message

    /// Puts a message on the pane and records who wrote it.
    ///
    /// A message from anywhere but discovery also puts
    /// ``SyncCoordinator/isLocalNetworkDenied`` down, because that flag is a fact
    /// about *the sentence on screen* — the pane reads it to decide whether to
    /// offer an Open Settings button — rather than a standing reading of the
    /// privilege. Left up, a browse denied a moment ago would put that button
    /// under an unrelated pairing failure and send the user to a switch that has
    /// nothing to do with it.
    func showMessage(_ message: String, from origin: SyncCoordinator.MessageOrigin) {
        errorMessage = message
        messageOrigin = origin
        if origin != .discovery { isLocalNetworkDenied = false }
    }

    /// Takes the pane's message back, but only if `origin` is what put it there.
    ///
    /// The whole point: a browse returning to `.ready` says nothing about a
    /// pairing that failed a second earlier, and used to wipe it anyway.
    func clearMessage(from origin: SyncCoordinator.MessageOrigin) {
        guard messageOrigin == origin else { return }
        errorMessage = nil
        isLocalNetworkDenied = false
    }

    private func descriptor(for runtime: SyncRuntime) -> ServiceDescriptor {
        ServiceDescriptor(
            displayName: displayName,
            port: UInt16(syncServer?.port ?? 0),
            deviceID: runtime.deviceID,
            platform: runtime.platform,
            // Advertised only while the window is open, so its absence tells a
            // peer this device will refuse a pairing dial rather than leaving it
            // to find out by being disconnected.
            pairingPort: pairingServer.map { UInt16($0.port) }
        )
    }
}
