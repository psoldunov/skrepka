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
    /// The two rules that stop a push looping or leaking are in
    /// ``LivePushGate``, which is where they can be tested; what is decided here
    /// is only which peers a pushable clipping goes to.
    func offerLivePush(_ item: ClipItem) {
        guard isEnabled,
            LivePushGate.isPushable(
                contentHash: item.contentHash,
                isConcealed: item.isConcealed,
                recentlyReceived: recentlyReceived,
                at: Date()
            )
        else { return }
        let targets = paired.keys.filter { livePushSetting(for: $0).isOn }
        guard !targets.isEmpty, let meta = meta(for: item) else { return }

        let payloads = Self.wirePayloads(item.payload)
        for deviceID in targets {
            guard let link = links[deviceID] else { continue }
            Task { await link.push(meta, payloads: payloads) }
        }
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
    /// The hash is remembered **before** the write, not after: the write is what
    /// the watcher might see, so a set updated afterwards would be updated after
    /// the race it exists to lose.
    ///
    /// **The clipboard write happens only for an item whose bytes came inline,
    /// and that is a known limitation of this phase rather than the intent.**
    /// `LivePushPayload.inline` sends nothing when a push's representations
    /// total more than `SyncLimits.livePushInlineLimit` (256 KB), which is most
    /// images. The `inline.isEmpty` guard below then declines, so the handoff
    /// the user is watching for does not happen. The item is still in history —
    /// `SyncResponder` stored it before calling this — and its bytes arrive on
    /// the next exchange, within `PeerLink.resyncInterval`, after which it
    /// pastes normally from the picker.
    ///
    /// Fetching the bytes here instead is **not** a small change, and the reason
    /// is `SyncInitiator`. `LivePushSink` carries no peer identity, so this has
    /// nothing to name the link to fetch over; and were that fixed, the fetch
    /// would be a second concurrent requester on an initiator whose
    /// `fetchPayload` awaits between its `send` and its `expect`. Two interleaved
    /// requests on one initiator take each other's `payloadChunk` replies.
    /// Turn-taking survives live push today precisely because a push expects no
    /// answer; a fetch does. So this needs a request lock on `SyncInitiator`
    /// first, and that is the change that would stop
    /// ``SkrepkaSync/SyncInitiator``'s no-correlation-identifier argument being
    /// true. Recorded under step 4 in `docs/linux-sync/phase-3-runbook.md`.
    func receiveLivePush(_ meta: SyncClipMeta, inline: [RepresentationKey: Data]) async {
        guard isEnabled, !meta.isConcealed, !inline.isEmpty else { return }
        recentlyReceived.remember(meta.contentHash, at: Date())
        await livePushReceiver.write(meta, payloads: inline)
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
