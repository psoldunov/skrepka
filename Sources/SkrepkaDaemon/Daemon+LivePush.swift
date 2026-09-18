import Foundation
import SkrepkaIPC
import SkrepkaSync

/// Live push per paired peer: resolving it for a capture and for a client, and
/// recording the user's choice.
///
/// One file so that the push gate and the documents a settings window reads
/// resolve the setting through the same function. Two resolutions — one for
/// pushing, one for showing — is how a switch ends up drawn on for a peer that
/// is not receiving anything.
extension Daemon {
    /// Whether live push is on for one peer, after the user's override has been
    /// resolved against design §3's platform default.
    func isLivePushOn(for deviceID: SyncDeviceID) async -> Bool {
        await livePushSetting(for: deviceID).isOn
    }

    /// The platform default for one peer and whatever the user chose instead.
    ///
    /// The peer's platform is its link's: what the pairing recorded until the
    /// link has connected this run, and what the peer's `hello` said from then
    /// on — see ``beginTracking(_:)``.
    func livePushSetting(for deviceID: SyncDeviceID) async -> LivePushSetting {
        LivePushSetting(
            local: .linux,
            remote: progress[deviceID]?.platform ?? .unknown,
            choice: await livePushChoice(for: deviceID)
        )
    }

    /// What the user chose for one peer, or `off` while that cannot be read.
    ///
    /// **Fails closed.** The platform default is on between Linux and anything
    /// else, so falling back to it would push the clipboard to a device the
    /// user turned off whenever the store could not say so. Held off instead,
    /// a failed read costs only immediacy: history still carries each copy
    /// within half a minute. Not reported: this runs once per peer on every
    /// capture, so a store that stays unreadable would flood the log, and a
    /// failed capture is worse than a quiet one.
    private func livePushChoice(for deviceID: SyncDeviceID) async -> LivePushChoice {
        do {
            return try await trust.livePushChoice(for: deviceID)
        } catch {
            return .off
        }
    }

    /// Starts the progress row a paired peer's link reports into, knowing the
    /// peer's platform from its pairing record.
    ///
    /// Seeded rather than left unknown until the link connects: the platform
    /// decides the live-push default, and a Mac that is asleep would otherwise
    /// be drawn with the unrecognised-platform default — off — while the push
    /// gate and the document both read it from here. The record's platform was
    /// proved inside the tunnel, at pairing or at the last `hello` — see
    /// `PairedDeviceStoring.refreshPeerIdentity(_:)` — and this run's `hello`
    /// replaces it through ``apply(_:to:)``.
    func beginTracking(_ peer: PairedPeer) {
        progress[peer.deviceID] = PeerProgress(platform: peer.platform)
    }

    /// Records the user's live-push choice for one paired device.
    ///
    /// Takes effect on the next copy: the push loop resolves the setting per
    /// capture rather than caching it, so there is no link to restart.
    public func setLivePush(device selector: String, choice: LivePushChoice) async -> ActionDocument {
        let peer: PairedPeer
        switch await pairedPeer(matching: selector) {
        case .found(let match): peer = match
        case .refused(let answer): return answer
        }
        do {
            try await trust.setLivePushChoice(choice, for: peer.deviceID)
        } catch {
            return .refused("could not save that: \(error)")
        }
        let isOn = await isLivePushOn(for: peer.deviceID)
        return .succeeded(
            "live clipboard is \(isOn ? "on" : "off") for \(peer.deviceName)",
            subject: peer.deviceID.fingerprint
        )
    }

    /// The name ``SkrepkaIPC/PeerDocument/livePushDefault`` carries for a
    /// default. Exhaustive on purpose, so a new case is a compile error here
    /// rather than a string no client recognises.
    static func wireName(_ reason: LivePushDefault) -> String {
        switch reason {
        case .on: PeerDocument.LivePushDefaultName.on
        case .offBetweenAppleDevices: PeerDocument.LivePushDefaultName.offBetweenAppleDevices
        case .offForUnrecognisedPlatform: PeerDocument.LivePushDefaultName.offForUnrecognisedPlatform
        }
    }
}
