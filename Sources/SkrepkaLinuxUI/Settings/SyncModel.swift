import Foundation
import SkrepkaIPC

/// Everything the Settings window knows, and every decision it makes about
/// what happened.
///
/// The window's widgets read this and send ``SyncAction``s; they decide
/// nothing. Which prompt is up, what a finished action means, when a code has
/// run out — all of it is here, as pure functions of the previous value, which
/// is what makes it testable without a display or a daemon.
///
/// Every transition returns a new value. The stored properties are `var` only
/// so a transition can build its result from a copy of `self`; nothing outside
/// this type can write them, and no instance is ever changed in place.
public struct SyncModel: Sendable, Hashable {
    /// The daemon's last answer about this device and its peers.
    public private(set) var peers: PeersDocument?
    /// Why the last poll failed, until one succeeds.
    public private(set) var failure: SyncFailure?
    /// Actions sent and not yet finished, oldest first.
    public private(set) var inFlight: [SyncAction] = []
    /// When the pairing window this window opened closes by itself. Unknown
    /// for a window somebody else opened — `skrepka pair` — which the peer
    /// list still shows as open.
    public private(set) var pairingWindowEndsAt: Date?
    /// The pairing a person is being asked about.
    public private(set) var prompt: PairingPrompt?
    /// Peers that dialled while ``prompt`` was already up, in arrival order.
    public private(set) var waiting: [PairingProposalDocument] = []
    public private(set) var notice: SyncNotice?

    public init() {}

    // MARK: - Reading

    public func isInFlight(_ action: SyncAction) -> Bool {
        inFlight.contains(action)
    }

    func peer(_ deviceID: String) -> PeerDocument? {
        peers?.peers.first { $0.deviceID == deviceID }
    }

    /// Whether this device can pair or share at all: the daemon answered, and
    /// it was not started with `--no-sync`, which leaves it without an
    /// identity to pair with.
    public var isSyncAvailable: Bool {
        guard failure == nil, let peers else { return false }
        return !peers.localFingerprint.isEmpty
    }

    // MARK: - Transitions

    /// This model with `action` sent: in flight, and — for a dial or an
    /// answer — the prompt moved to match.
    public func sending(_ action: SyncAction) -> SyncModel {
        var next = self
        next.inFlight.append(action)
        switch action {
        case .pair(let deviceID):
            if next.prompt == nil, let peer = peer(deviceID) {
                next.prompt = .dialling(peer)
            }
        case .answer(let deviceID, let accept):
            if let prompt, prompt.deviceID == deviceID, prompt.stage == .comparing {
                next.prompt = prompt.moved(to: .answering(accept: accept))
            }
        case .openPairingWindow, .closePairingWindow, .unpair, .setLivePush, .syncNow:
            break
        }
        return next
    }

    public func applying(_ event: SyncEvent, now: Date) -> SyncTransition {
        switch event {
        case .refreshed(let document):
            return SyncTransition(model: refreshed(document))
        case .unreachable(let failure):
            var next = self
            next.failure = failure
            return SyncTransition(model: next)
        case .finished(let action, let result, let document):
            return finishing(action, result, refreshed: document, now: now)
        case .pairingRequested(let proposal):
            return requested(proposal, now: now)
        case .shutDown:
            return SyncTransition(model: self)
        }
    }

    /// Whatever has run out by `now`: a code nobody confirmed, peers that gave
    /// up waiting behind it, good news that has been up long enough.
    public func expiring(now: Date) -> SyncModel {
        var next = self
        if let prompt, prompt.stage == .comparing, let expiresAt = prompt.expiresAt, expiresAt <= now {
            next.prompt = prompt.moved(to: .ended(PairingPrompt.tookTooLong))
        }
        next.waiting = waiting.filter { $0.expiresAt > now }
        if let clearsAt = notice?.clearsAt, clearsAt <= now {
            next.notice = nil
        }
        if let endsAt = pairingWindowEndsAt, endsAt <= now {
            next.pairingWindowEndsAt = nil
        }
        return next
    }

    public func dismissingNotice() -> SyncModel {
        var next = self
        next.notice = nil
        return next
    }

    /// Cancel, Close, Escape or the title bar's close button on the prompt.
    ///
    /// A code on screen is *answered* no rather than dropped: the daemon holds
    /// the far side's proposal until it hears, and a silent close would leave
    /// the other machine waiting out its whole timeout.
    public func cancellingPrompt(now: Date) -> SyncTransition {
        guard let prompt else { return SyncTransition(model: self) }
        switch prompt.stage {
        case .comparing:
            return SyncTransition(model: self, effects: [.answer(deviceID: prompt.deviceID, accept: false)])
        case .answering:
            return SyncTransition(model: self)
        case .dialling, .ended:
            var next = self
            next.prompt = nil
            return SyncTransition(model: next.promotingWaiting(now: now))
        }
    }

    // MARK: - Pieces

    func refreshed(_ document: PeersDocument) -> SyncModel {
        var next = self
        next.peers = document
        next.failure = nil
        if document.pairingPort == nil {
            next.pairingWindowEndsAt = nil
        }
        return next
    }

    func withPrompt(_ prompt: PairingPrompt?) -> SyncModel {
        var next = self
        next.prompt = prompt
        return next
    }

    func withNotice(_ notice: SyncNotice?) -> SyncModel {
        var next = self
        next.notice = notice
        return next
    }

    func withPairingWindowEnding(_ date: Date?) -> SyncModel {
        var next = self
        next.pairingWindowEndsAt = date
        return next
    }

    func withoutInFlight(_ action: SyncAction) -> SyncModel {
        var next = self
        if let index = inFlight.firstIndex(of: action) {
            next.inFlight.remove(at: index)
        }
        return next
    }

    func withWaiting(_ waiting: [PairingProposalDocument]) -> SyncModel {
        var next = self
        next.waiting = waiting
        return next
    }
}
