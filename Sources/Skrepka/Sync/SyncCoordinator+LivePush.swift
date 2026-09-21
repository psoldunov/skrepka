import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// Live push, both directions, and the two things that stop it looping.
extension SyncCoordinator {
    // MARK: - Sending

    /// Offers a locally captured item to every peer that takes live pushes.
    ///
    /// Called from `AppCoordinator`'s existing capture loop rather than from a
    /// watcher of its own — one watcher, one `changeCount`, one source of truth
    /// about what was copied.
    ///
    /// The rules that stop a push looping or leaking are in ``LivePushGate``,
    /// which is where they can be tested; what is decided here is only which
    /// peers a pushable clipping goes to.
    ///
    /// The gate hears about every capture, before `isEnabled` is asked — see
    /// ``LivePushGate/admitCopy(_:isConcealed:at:)`` for why.
    func offerLivePush(_ item: ClipItem) {
        let admitted = livePushGate.admitCopy(
            item.contentHash, isConcealed: item.isConcealed, at: Date())
        guard isEnabled, admitted else { return }
        let targets = paired.keys.filter { livePushSetting(for: $0).isOn }
        guard !targets.isEmpty, let meta = meta(for: item) else { return }

        let payloads = Self.wirePayloads(item.payload)
        for deviceID in targets {
            guard let link = links[deviceID] else { continue }
            Task { await link.push(meta, payloads: payloads) }
        }
    }

    /// Tells the gate about a copy that was not recorded — refused by the
    /// capture rules, or lost to a store that failed.
    ///
    /// Nothing goes to peers, but it is still a copy, so it ends a hand-over
    /// as a recorded one would — the same transition the daemon makes, see
    /// ``LivePushGate/noteUnrecordedCopy(_:)``.
    func noteUnrecordedCopy(_ contentHash: String? = nil) {
        livePushGate.noteUnrecordedCopy(contentHash)
    }

    /// The item as a peer is told about it.
    ///
    /// Nil before this device has an identity, which is the same condition under
    /// which the store refuses to build an index at all: `SyncClipMeta` names
    /// the device that recorded the content, and `SyncDeviceID` is derived from
    /// a certificate rather than invented.
    private func meta(for item: ClipItem) -> SyncClipMeta? {
        guard let localDeviceID else { return nil }
        let representations = item.payload.representations.compactMap { type, data in
            RepresentationKeyMap.key(forUTI: type)
                .map { RepresentationDescriptor(key: $0, byteCount: data.count) }
        }
        return SyncClipMeta(
            contentHash: item.contentHash,
            kind: item.kind.rawValue,
            preview: item.text,
            createdAt: item.createdAt,
            isPinned: LWWRegister(
                value: item.isPinned,
                timestamp: item.createdAt,
                deviceID: localDeviceID
            ),
            isConcealed: item.isConcealed,
            imageWidth: item.imageSize?.width,
            imageHeight: item.imageSize?.height,
            sourceBundleID: item.sourceBundleID,
            originDeviceID: localDeviceID,
            representations: representations
        )
    }

    /// Pasteboard-keyed bytes as wire-keyed bytes.
    ///
    /// A type with no canonical media type is dropped rather than renamed —
    /// `RepresentationKeyMap` refusing to name it means no peer could read those
    /// bytes anyway, and `com.apple.flat-rtfd` is the case that matters.
    private static func wirePayloads(_ payload: ClipPayload) -> [RepresentationKey: Data] {
        var wire: [RepresentationKey: Data] = [:]
        for (type, data) in payload.representations {
            guard let key = RepresentationKeyMap.key(forUTI: type) else { continue }
            wire[key] = data
        }
        return wire
    }

    // MARK: - Receiving

    /// Puts content a peer pushed onto this Mac's pasteboard.
    ///
    /// The item is already in history by the time this runs —
    /// `SyncResponder` stores before it calls the sink — so everything here is
    /// about the clipboard and nothing here can cost the row.
    ///
    /// Noted as awaited, then claimed once the write is ready — see
    /// ``claimForWrite(_:)``. The claim records the push as received before
    /// the write, which is what keeps its echo from being pushed back.
    ///
    /// A push over `SyncLimits.livePushInlineLimit` (256 KB, so most pictures
    /// and file copies) arrives with no bytes and is declined here; the
    /// responder then asks for them — see ``fetchPushedBytes(of:from:)``.
    func receiveLivePush(_ meta: SyncClipMeta, inline: [RepresentationKey: Data]) async {
        guard isEnabled, !meta.isConcealed, !inline.isEmpty else { return }
        livePushGate.noteAwaitingBytes(meta.contentHash)
        await livePushReceiver.write(meta, payloads: inline) { [weak self] in
            self?.claimForWrite(meta.contentHash) ?? false
        }
    }

    /// A peer pushed an item without its bytes: fetch them now, over the link
    /// to that peer, rather than on its next exchange.
    ///
    /// Over the link rather than the connection the push came in on: the link's
    /// initiator is the one side that may request bytes, and it takes one
    /// request at a time. The gate is told first, so a copy made while the
    /// fetch runs wins — see ``LivePushGate/claimFetched(_:at:)``.
    func fetchPushedBytes(of meta: SyncClipMeta, from sender: SyncDeviceID) async {
        guard isEnabled, let link = links[sender] else { return }
        livePushGate.noteAwaitingBytes(meta.contentHash)
        await link.fetchPushed(meta)
    }

    /// The bytes of a push that came without them have been fetched and
    /// stored. Written to the pasteboard only if nothing has happened since
    /// that the user would expect to find there instead.
    func receiveFetchedPush(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async {
        guard isEnabled, !meta.isConcealed, !payloads.isEmpty else { return }
        await livePushReceiver.write(meta, payloads: payloads) { [weak self] in
            self?.claimForWrite(meta.contentHash) ?? false
        }
    }

    /// Whether a push may go on the pasteboard now: sync still on, and nothing
    /// copied or pushed here since. Asked by the receiver after its files are
    /// written and immediately before the write, as the Linux daemon does in
    /// `Daemon+Handoff.swift`.
    private func claimForWrite(_ contentHash: String) -> Bool {
        isEnabled && livePushGate.claimFetched(contentHash, at: Date())
    }

    // MARK: - The per-peer switch

    /// Records the user's live-push choice for one peer.
    ///
    /// **Synchronous, and queues the write**, for the reason
    /// ``SyncCoordinator/enqueueSetting(_:)`` exists: the caller is a `Binding`
    /// setter, so a caller that started its own task would hand two quick flips
    /// to two unordered tasks and persist whichever finished last rather than
    /// whichever the user chose last. Off-then-on landing as on is this switch
    /// continuing to send a peer everything the user copies, after they turned
    /// it off.
    func setLivePush(_ choice: LivePushChoice, for deviceID: SyncDeviceID) {
        enqueueSetting { [weak self] in
            guard let self, let runtime else { return }
            do {
                try await runtime.trust.setLivePushChoice(choice, for: deviceID)
                livePushChoices[deviceID] = choice
                refreshRows()
            } catch {
                showMessage("Skrepka could not save that setting.", from: .elsewhere)
                SkrepkaLog.sync.error(
                    "Saving a live-push choice failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }
}
