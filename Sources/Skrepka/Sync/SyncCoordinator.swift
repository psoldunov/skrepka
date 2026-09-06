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
/// The other half of this type is in `SyncCoordinator+Serving.swift`,
/// `SyncCoordinator+Discovery.swift`, `SyncCoordinator+Pairing.swift` and
/// `SyncCoordinator+LivePush.swift`. Swift scopes `private` to the file, so
/// everything they touch is internal.
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
            Task { isEnabled ? await start() : await stop() }
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

    var acceptTask: Task<Void, Never>?
    var pairingAcceptTask: Task<Void, Never>?
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

    init(preferences: Preferences, store: HistoryStore, livePushReceiver: LivePushReceiver) {
        self.preferences = preferences
        self.store = store
        self.livePushReceiver = livePushReceiver
        trust = KeychainTrustStore(peers: store)
        displayName = Self.deviceName()
        isEnabled = preferences.syncEnabled
    }

    // MARK: - Lifecycle

    /// Brings sync up, or does nothing when the user has it switched off.
    ///
    /// Every failure lands in ``errorMessage`` rather than throwing: this is
    /// called from `AppCoordinator.start()`, where there is nobody to catch it,
    /// and a Mac that cannot open a listening socket should still be a
    /// clipboard manager.
    func start() async {
        guard isEnabled, runtime == nil else { return }
        errorMessage = nil
        do {
            try await bringUp()
        } catch {
            errorMessage = SyncFailureText.describe(error)
            SkrepkaLog.sync.error(
                "Sync could not start: \(String(describing: error), privacy: .public)"
            )
            await stop()
        }
    }

    func stop() async {
        // Anyone parked on a sheet is answered "no" before the machinery that
        // would have carried a "yes" goes away. A continuation that is never
        // resumed is a task suspended for the life of the process.
        answerPairing(false)
        pendingPairing = nil
        isPairingInFlight = false

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

        await stopPairingListener()
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
        refreshRows()
    }

    private func bringUp() async throws {
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
        try await startDiscovery(runtime: runtime)
        reconcileLinks()
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
    private static func deviceName() -> String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "Mac" : name
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
