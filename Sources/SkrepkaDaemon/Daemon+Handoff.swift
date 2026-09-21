import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

// Content a peer pushed, put onto this machine's clipboard — whether its bytes
// came inline or were fetched right after the push.
extension Daemon {
    /// Puts content a peer pushed onto this machine's clipboard.
    ///
    /// The item is already in history by the time this runs — `SyncResponder`
    /// stores before it calls the sink — so everything here is about the
    /// clipboard and nothing here can cost the row.
    ///
    /// **A push whose bytes did not come inline writes nothing here.** The
    /// responder goes on to call ``fetchPushed(_:from:generation:)``, and the
    /// bytes reach the clipboard through ``receiveFetchedPush(_:payloads:generation:)``
    /// once they land.
    ///
    /// **A push from a sync stack that has since stopped writes nothing.** The
    /// row is already stored, which is the index exchange's business, but a
    /// user who turned sync off must not have a peer overwrite the clipboard.
    ///
    /// - Returns: whether the push was taken for the clipboard.
    @discardableResult
    func receiveLivePush(
        _ meta: SyncClipMeta,
        inline: [RepresentationKey: Data],
        generation: Int
    ) async -> Bool {
        guard isSyncCurrent(generation), !meta.isConcealed, !inline.isEmpty else { return false }
        notifyHistoryChanged()
        // Noted as waiting, then claimed: a file push is written to disk
        // before it reaches the clipboard, and a copy made on this machine
        // during that write must win over it. The gate's claim is what says so.
        livePushGate.noteAwaitingBytes(meta.contentHash)
        await writeHandoff(meta, payloads: inline, generation: generation)
        return true
    }

    /// A peer pushed something too large to carry inline — most pictures, and
    /// any file copy over the inline limit. Asks that peer's link for the bytes
    /// now rather than on the exchange half a minute away.
    ///
    /// Nothing is fetched for a sender with no link here: the link is the only
    /// thing that can ask, and the next exchange with it fetches the row anyway.
    func fetchPushed(_ meta: SyncClipMeta, from sender: SyncDeviceID, generation: Int) async {
        guard isSyncCurrent(generation), !meta.isConcealed, let link = links[sender] else { return }
        notifyHistoryChanged()
        livePushGate.noteAwaitingBytes(meta.contentHash)
        await link.fetchPushed(meta)
    }

    /// The bytes of a push fetched by ``fetchPushed(_:from:generation:)`` have
    /// been stored. Written to the clipboard only if nothing was copied or
    /// pushed here since — see `LivePushGate.claimFetched(_:at:)`.
    func receiveFetchedPush(
        _ meta: SyncClipMeta,
        payloads: [RepresentationKey: Data],
        generation: Int
    ) async {
        guard isSyncCurrent(generation), !meta.isConcealed, !payloads.isEmpty else { return }
        notifyHistoryChanged()
        await writeHandoff(meta, payloads: payloads, generation: generation)
    }

    /// Writes a push the gate is waiting on, as a handoff.
    ///
    /// **No pause around the write, because a pause cannot cover it.**
    /// ``SkrepkaLinuxPlatform/SelectionWrite/handoff`` is what keeps it out of
    /// capture: the session remembers why it owns the selection and publishes
    /// nothing for its own echo.
    private func writeHandoff(
        _ meta: SyncClipMeta,
        payloads: [RepresentationKey: Data],
        generation: Int
    ) async {
        guard
            let targets = await handoffTargets(
                meta, payloads: payloads, generation: generation, requiringClipboard: true),
            let clipboard
        else { return }
        await clipboard.setSelection(targets, as: .handoff)
    }

    /// The targets to hand over for a push the gate is waiting on, or nil when
    /// nothing should be written — and when the answer is targets, the gate has
    /// already recorded the handoff.
    ///
    /// **The gate hears of the handoff only once the write is certain.** No
    /// session to write to — GNOME Wayland, where the Shell extension submits
    /// clips instead — or no target the payload converts to leaves the
    /// clipboard as it was, and a handoff recorded anyway would refuse the
    /// next local copy of the same content for nothing. Every check runs after
    /// the last suspension, so nothing can change between them and the write.
    ///
    /// - Parameter requiringClipboard: false only in tests, which have no
    ///   session and still want to see what would be written.
    func handoffTargets(
        _ meta: SyncClipMeta,
        payloads: [RepresentationKey: Data],
        generation: Int,
        requiringClipboard: Bool
    ) async -> [String: Data]? {
        let source = WritableRow(
            kind: ClipKind(rawValue: meta.kind) ?? .text,
            representations: RepresentationKeyMap.utiKeyed(payloads),
            fileURLs: [],
            preview: meta.preview,
            contentHash: meta.contentHash,
            isForeign: runtime.map { meta.originDeviceID != $0.deviceID } ?? true
        )
        let targets = await clipboardWrite(for: source).targets
        guard isSyncCurrent(generation), !targets.isEmpty,
            clipboard != nil || !requiringClipboard,
            livePushGate.claimFetched(meta.contentHash, at: Date())
        else { return nil }
        return targets
    }
}
