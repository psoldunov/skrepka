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
    func livePushSetting(for deviceID: SyncDeviceID) async -> LivePushSetting {
        // A read that fails falls back to the platform default, deliberately.
        // This runs once per peer on every capture, so it cannot report or
        // propagate without turning a locked store into a log flood or into a
        // failed capture; and the default is the setting the user has not
        // overridden, which is the safe answer to give when the override
        // cannot be read.
        let choice = (try? await trust.livePushChoice(for: deviceID)) ?? .followsPlatformDefault
        return LivePushSetting(
            local: .linux,
            remote: progress[deviceID]?.platform ?? .unknown,
            choice: choice
        )
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
