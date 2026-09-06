import Foundation
import NIOCore
import NIOPosix
import Observation
import SkrepkaCore
import SkrepkaSync
import os

/// Everything sync owns, in one object hanging off ``AppCoordinator`` beside
/// `watcher`, `store` and `statusItem`.
///
/// It owns the device identity, the two listeners, the Bonjour advertiser and
/// browser, one ``PeerLink`` per paired peer, and the set of hashes a peer
/// pushed here a moment ago. `@MainActor` like everything else in the app
/// target; the connections underneath it are actors.
///
/// **Two listeners, and they cannot be one.** ``syncServer`` is pinned — its
/// TLS callback accepts only certificates the user has already approved — and
/// pairing is by definition a connection from a device with nothing pinned. A
/// single listener would have to accept any well-formed leaf on the port that
/// also serves history, which is exactly what `PinPolicy` exists to prevent. So
/// ``pairingServer`` is a second one, running only while the user has asked to
/// pair, and its port is advertised as `pair=` so a peer knows where to dial.
/// A device that is not pairing advertises no such key and cannot complete a
/// handshake with a stranger at all.
///
/// The other half of this type is in `SyncCoordinator+Lifecycle.swift`,
/// `SyncCoordinator+Serving.swift`, `SyncCoordinator+Discovery.swift`,
/// `SyncCoordinator+Pairing.swift` and `SyncCoordinator+LivePush.swift`. Swift
/// scopes `private` to the file, so everything they touch is internal.
///
/// This file is the type, its state, and the switch that drives it. Bringing
/// sync up and taking it down is next door, because those two are what the
/// state above exists to be mutated by, and keeping them together is what makes
/// the ordering rule in ``enqueueLifecycle(_:)`` readable in one place.
@MainActor
@Observable
final class SyncCoordinator {
    /// Whether the user has switched sync on at all.
    ///
    /// Off by default. Sync opens a listening socket and publishes this machine
    /// on the local network, and neither is a thing to start doing to somebody
    /// who upgraded for a clipboard manager.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            preferences.syncEnabled = isEnabled
            // `wanted` is captured here rather than read inside the task, and the
            // work is queued *synchronously* from `didSet`. Both matter: two
            // bare `Task {}`s are unordered, so a quick off-on used to run the
            // bring-up first, find `runtime` still non-nil from the tear-down
            // behind it, and return — leaving the switch reading on with nothing
            // listening. See ``enqueueLifecycle(_:)``.
            let wanted = isEnabled
            enqueueLifecycle { [weak self] in
                guard let self else { return }
                wanted ? await performStart() : await performStop()
            }
        }
    }

    /// Whether the pairing listener is up and `pair=` is being advertised.
    ///
    /// A window the user opens rather than a permanent state: see the type's
    /// note on why the second listener exists.
    var isAcceptingPairing = false

    /// This device's own identity, once the Keychain has answered.
    var localDeviceID: SyncDeviceID?

    /// What this device calls itself on the network.
    let displayName: String

    /// Paired peers first, then devices merely seen, both sorted by name.
    var peers: [SyncPeerRow] = []

    /// The pairing waiting on the user, if any. Drives the sheet.
    var pendingPairing: PendingPairing?

    /// Non-nil when sync could not start or has stopped working. Surfaced in
    /// the Sync pane the way `AppCoordinator.startupError` is, rather than
    /// left in a log line nobody reads.
    var errorMessage: String?

    /// Whether macOS is currently refusing this app the local network.
    ///
    /// Held apart from ``errorMessage`` because it is the one sync failure with
    /// a button behind it: the pane offers System Settings for this and for
    /// nothing else. See ``SyncCoordinator/performPublish()`` for what it gates.
    var isLocalNetworkDenied = false

    /// Which part of sync wrote ``errorMessage``.
    ///
    /// One line on the pane is shared by everything that can fail, and only one
    /// of them ever *clears* it: a browse reaching `.ready` used to wipe the slot
    /// unconditionally. That slot also carries a pairing that failed, a
    /// live-push setting that would not save and a listener that would not
    /// rebind, and a browse recovering has nothing to say about any of those —
    /// so the clear now asks whether the message was discovery's to take back.
    ///
    /// See ``SyncCoordinator/showMessage(_:from:)``.
    enum MessageOrigin { case discovery, elsewhere }
    var messageOrigin: MessageOrigin = .elsewhere

    // Internal rather than private, and the published state above is internal
    // rather than `private(set)`, for one reason: the five extension files are
    // the rest of this type, and Swift scopes both `private` and a
    // `private(set)` setter to the file they are written in.

    let preferences: Preferences
    /// The concrete store, for the parts of pairing that are not
    /// `HistoryStoring` — publishing `localDeviceID` into it, and reading the
    /// live-push choice a row shows.
    let store: HistoryStore
    let trust: KeychainTrustStore

    var runtime: SyncRuntime?
    var group: MultiThreadedEventLoopGroup?
    var syncServer: SyncServer?
    var pairingServer: SyncServer?
    var discovery: BonjourDiscovery?

    /// Whether this device is published and dialling its peers.
    ///
    /// Sync comes up in two steps, and this is the line between them. Everything
    /// up to and including the pinned listener needs no permission from macOS;
    /// publishing the record and dialling a peer both do, so they wait for the
    /// browse to report that the permission is there. See
    /// ``SyncCoordinator/bringUp()``.
    var isPublished = false

    /// How many times publishing has been retried for the failure it is on now,
    /// reset by a publish that works. See `SkrepkaSync.PublishRetryPolicy`.
    var publishAttempts = 0

    /// The one outstanding retry of ``SyncCoordinator/performPublish()``.
    ///
    /// One, and replaced rather than stacked: a second failure cancels whatever
    /// this holds before scheduling its own, so the schedule cannot be walked by
    /// two timers at once. Cancelled and nilled by ``performStop()`` like every
    /// other task here, because a retry that outlived a tear-down would publish
    /// a device that has switched sync off.
    var publishRetryTask: Task<Void, Never>?

    var acceptTask: Task<Void, Never>?
    var pairingAcceptTask: Task<Void, Never>?
    /// Closes the pairing window if nothing pairs through it — see
    /// ``SyncCoordinator/pairingWindow``.
    var pairingExpiryTask: Task<Void, Never>?

    /// Which pairing window is open, counted up each time one is.
    ///
    /// Two things decide to close a window — a device paired, or the window
    /// expired — and each decides *before* its work reaches the lifecycle queue.
    /// Ordering alone cannot tell whether the window running when the work gets
    /// there is the same one the decision was about, and the case is not
    /// hypothetical: pairing a device closes the window, and the obvious next
    /// thing a user does is reopen it to pair a second device. Without this, a
    /// close decided a moment before that reopen shuts the new window instead.
    var pairingWindowGeneration = 0
    var browseTask: Task<Void, Never>?

    /// Devices seen on the network this session, by identifier. The browse
    /// result is what ``PeerLink`` resolves against immediately before dialling.
    var sighted: [SyncDeviceID: SightedPeer] = [:]
    /// Paired peers as the trust store holds them.
    var paired: [SyncDeviceID: PairedPeer] = [:]
    var livePushChoices: [SyncDeviceID: LivePushChoice] = [:]
    var links: [SyncDeviceID: PeerLink] = [:]
    var progress: [SyncDeviceID: PeerProgress] = [:]

    /// Hashes a peer pushed here recently, so none of them is pushed back.
    var recentlyReceived = RecentHashes()

    /// Whether a pairing this device started is between its first `await` and
    /// its sheet.
    ///
    /// The slot ``pendingPairing`` occupies has to be reserved *synchronously*,
    /// and it cannot be reserved by that property: ``pair(with:)`` resolves an
    /// address and completes a TLS handshake before it has a proposal to show,
    /// and a peer dialling in during that window would find the slot empty, open
    /// its own sheet, and install its own ``pairingAnswer`` — which the outgoing
    /// pairing then overwrites. A dropped `CheckedContinuation` is a permanent
    /// hang, not a lost sheet.
    var isPairingInFlight = false

    /// Whoever is waiting on ``pendingPairing``.
    ///
    /// Held apart from the sheet's model because only one of the two is
    /// observable state: the sheet is what SwiftUI reads, and this is the
    /// suspended `pair`/`confirmPairing` call it will resume. Non-nil exactly
    /// while somebody is parked.
    var pairingAnswer: CheckedContinuation<Bool, Never>?

    /// Writes a received live push to the pasteboard.
    let livePushReceiver: LivePushReceiver

    /// The last queued change to the running stack, or nil if none has been
    /// asked for yet. See ``enqueueLifecycle(_:)``.
    var lifecycleTail: Task<Void, Never>?

    /// The last queued write to a per-peer setting. See ``enqueueSetting(_:)``.
    ///
    /// A second chain rather than the lifecycle one, because the two order
    /// different things and sharing a queue would make them wait on each other:
    /// flicking a peer's live-push switch has no business queuing behind a
    /// listener rebind, and a listener rebind must not be delayed by a Keychain
    /// write.
    var settingTail: Task<Void, Never>?

    /// Whether ``performStop()`` has begun.
    ///
    /// Set as its first statement and cleared as its last, because tearing down
    /// takes several awaits and this actor is re-entrant across every one of
    /// them. Anything that can rebuild part of the stack — ``reconcileLinks()``
    /// above all — has to be able to tell "sync is running" from "sync is in the
    /// middle of going away", and `runtime` cannot say so: it is nilled at the
    /// *end* of the tear-down, so for the whole of it a browse event or a
    /// finishing `serve` task would read a live coordinator and rebuild links
    /// that nothing will ever stop again.
    var isTearingDown = false

    init(preferences: Preferences, store: HistoryStore, livePushReceiver: LivePushReceiver) {
        self.preferences = preferences
        self.store = store
        self.livePushReceiver = livePushReceiver
        trust = KeychainTrustStore(peers: store)
        displayName = Self.deviceName()
        isEnabled = preferences.syncEnabled
    }

}

/// A device seen on the network, with the browse result needed to resolve it
/// again.
struct SightedPeer: Sendable {
    let peer: DiscoveredPeer
    let advertisement: PeerAdvertisement
}

/// What one peer's link has reported so far this session.
struct PeerProgress: Sendable, Hashable {
    var link: SyncPeerRow.Link = .idle
    var name: String?
    var platform: PeerPlatform?
    var lastSyncedAt: Date?
    var received = 0
    var pushed = 0
}
