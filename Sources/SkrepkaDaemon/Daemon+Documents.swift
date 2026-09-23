import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaLinuxPlatform
import SkrepkaSync

extension Daemon {
    /// The history, as a client sees it.
    ///
    /// `limit` of 0 is every entry. The total is always the whole count, so a
    /// menu can say "showing 20 of 400" without a second call.
    public func historyDocument(limit: UInt32) async -> HistoryDocument {
        let listing: [SQLiteHistoryStore.ClipListing]
        do {
            listing = try await store.listing()
        } catch {
            // `HistoryDocument` has no error field and the interface's `History`
            // method does not throw, so an empty document is all this can
            // answer with. Logged so the failure exists somewhere: without it a
            // store that cannot be read is indistinguishable from an empty one,
            // in the one call a client makes most often.
            logger.error(
                "could not read the history for a client",
                metadata: ["error": .string(String(describing: error))]
            )
            return HistoryDocument(clips: [], total: 0)
        }
        let local = await localDeviceHex(ifAnyOf: listing)
        let fileLimit = settings.fileSync.maximumBytes
        let clips = listing.map { Self.clipDocument($0, localDeviceHex: local, fileLimit: fileLimit) }
        let limited = limit == 0 ? clips : Array(clips.prefix(Int(limit)))
        return HistoryDocument(clips: limited, total: clips.count)
    }

    static func clipDocument(
        _ listing: SQLiteHistoryStore.ClipListing,
        localDeviceHex: String? = nil,
        fileLimit: Int = FileSyncLimit.ceiling
    ) -> ClipDocument {
        let summary = listing.summary
        return ClipDocument(
            contentHash: listing.contentHash,
            // `previewText` rather than `text`: it is what masks a concealed
            // entry, and the macOS picker's licence to list one does not extend
            // to printing a password manager's clip into a terminal and its
            // scrollback. Flattened and bounded here rather than in each
            // client, so a GNOME menu and `skrepka list` render the same string
            // and neither can be made to run an escape sequence.
            preview: SafeText.oneLine(listing.summary.previewText),
            kind: summary.kind.rawValue,
            isPinned: summary.isPinned,
            createdAt: summary.createdAt,
            byteCount: summary.byteCount,
            // Canonical media types, not the store's pasteboard identifiers: a
            // client outside this process has no business knowing that a Linux
            // store indexes by macOS type identifiers, which is an artefact of
            // one mapping table rather than a fact about the clipboard.
            representations: listing.representationTypes
                .compactMap(RepresentationKeyMap.canonical(forUTI:))
                .sorted(),
            lineCount: summary.isConcealed || summary.kind.isFileSystemEntry || summary.kind == .image
                ? nil : summary.lineCount,
            imageWidth: summary.imageSize?.width,
            imageHeight: summary.imageSize?.height,
            fileCount: summary.fileCount > 0 ? summary.fileCount : nil,
            isConcealed: summary.isConcealed,
            hasPreview: !summary.isConcealed
                && Self.hasPicture(
                    listing, isForeign: isForeign(origin: listing.originDeviceID, local: localDeviceHex)),
            filesStatus: Self.filesStatus(listing, localDeviceHex: localDeviceHex, fileLimit: fileLimit)
        )
    }

    /// Whether ``Daemon/preview(_:maxBytes:)`` has a picture for the row: one
    /// held as itself, the one file of an image-file row's bundle, or — for a
    /// row copied on this device — the file on disk the row names.
    ///
    /// The store marks a row `imageFile` only when a picture's header was
    /// seen, in the bundle or at the head of the file, so the kind is the
    /// evidence. A foreign row without its bundle has nothing: its path names
    /// a file on the other machine.
    static func hasPicture(_ listing: SQLiteHistoryStore.ClipListing, isForeign: Bool) -> Bool {
        if pictureMediaType(in: listing.localRepresentationTypes) != nil { return true }
        guard listing.summary.kind == .imageFile else { return false }
        return !isForeign || listing.localRepresentationTypes.contains(FileBundle.storageType)
    }

    /// Whether a file row from another device brought its files, as the
    /// document spells it. Nil for anything else.
    static func filesStatus(
        _ listing: SQLiteHistoryStore.ClipListing,
        localDeviceHex: String?,
        fileLimit: Int = FileSyncLimit.ceiling
    ) -> String? {
        let status = SyncedFilesStatus.of(
            kind: listing.summary.kind,
            isForeign: isForeign(origin: listing.originDeviceID, local: localDeviceHex),
            offeredTypes: Set(listing.representationTypes),
            heldTypes: Set(listing.localRepresentationTypes),
            offeredBundleBytes: listing.fileBundleBytes,
            fileLimit: fileLimit
        )
        return switch status {
        case .synced: ClipDocument.FilesStatusName.synced
        case .pending: ClipDocument.FilesStatusName.pending
        case .notSynced: ClipDocument.FilesStatusName.notSynced
        case .overLimit: ClipDocument.FilesStatusName.overLimit
        case nil: nil
        }
    }

    /// The image kinds a GTK client can display directly, in the preference
    /// order its preview request follows. The map keeps this boundary in media
    /// types rather than leaking the store's UTI keys onto D-Bus.
    static let previewMediaTypes = PictureFormat.allCases.map(\.mediaType)

    static func pictureMediaType(in representationTypes: [String]) -> String? {
        let canonical = Set(representationTypes.compactMap(RepresentationKeyMap.canonical(forUTI:)))
        return previewMediaTypes.first(where: canonical.contains)
    }

    // MARK: - Peers

    public func peersDocument() async -> PeersDocument {
        // Logged and then treated as none: `PeersDocument` carries no error
        // field either, and the sighted-but-unpaired half of the list is still
        // worth answering with. Reporting it is what stops "no peers are
        // paired with this device" being the only trace of a store that is
        // merely locked.
        var paired: [PairedPeer] = []
        do {
            paired = try await trust.pairedPeers()
        } catch {
            logger.error(
                "could not read the paired devices for a client",
                metadata: ["error": .string(String(describing: error))]
            )
        }
        let pairedByID = Dictionary(paired.map { ($0.deviceID, $0) }) { first, _ in first }

        var documents: [PeerDocument] = []
        for peer in paired {
            documents.append(await peerDocument(deviceID: peer.deviceID, paired: peer))
        }
        for (deviceID, sighting) in sighted where pairedByID[deviceID] == nil {
            documents.append(await unpairedDocument(deviceID: deviceID, sighting: sighting))
        }

        return PeersDocument(
            localDeviceID: runtime?.deviceID.hex ?? "",
            localFingerprint: runtime?.deviceID.fingerprint ?? "",
            localName: displayName,
            // Paired first, then sighted-but-unpaired; by name inside each
            // group, so the list does not reorder itself as links change state.
            peers: documents.sorted {
                ($0.isPaired ? 0 : 1, $0.name ?? $0.fingerprint)
                    < ($1.isPaired ? 0 : 1, $1.name ?? $1.fingerprint)
            },
            pairingPort: pairingServer.map { UInt16($0.port) }
        )
    }

    private func peerDocument(deviceID: SyncDeviceID, paired: PairedPeer) async -> PeerDocument {
        let entry = progress[deviceID] ?? PeerProgress()
        let sighting = sighted[deviceID]
        let livePush = await livePushSetting(for: deviceID)
        return PeerDocument(
            deviceID: deviceID.hex,
            fingerprint: deviceID.fingerprint,
            // The name from `hello` outranks the advertisement's: that arrived
            // unauthenticated, this arrived inside the tunnel from the device
            // whose certificate is pinned. Sanitised either way — a pinned peer
            // still chose its own name.
            name: SafeText.oneLine(
                ifPresent: entry.name ?? paired.deviceName, limit: SafeText.nameLimit),
            platform: (entry.platform == .unknown ? paired.platform : entry.platform).rawValue,
            isPaired: true,
            isSighted: sighting != nil,
            isAcceptingPairing: sighting?.advertisement.isAcceptingPairing ?? false,
            linkState: entry.state,
            livePush: livePush.isOn,
            lastSyncedAt: entry.lastSyncedAt,
            livePushChoice: livePush.choice.rawValue,
            livePushDefault: Self.wireName(livePush.reason)
        )
    }

    private func unpairedDocument(deviceID: SyncDeviceID, sighting: Sighting) async -> PeerDocument {
        PeerDocument(
            deviceID: deviceID.hex,
            fingerprint: deviceID.fingerprint,
            // The worst case for this whole helper: an unpaired peer's name is
            // whatever anyone on the LAN put in a TXT record.
            name: SafeText.oneLine(
                ifPresent: sighting.advertisement.displayName ?? sighting.peer.instanceName,
                limit: SafeText.nameLimit
            ),
            platform: sighting.advertisement.platform.rawValue,
            isPaired: false,
            isSighted: true,
            isAcceptingPairing: sighting.advertisement.isAcceptingPairing,
            linkState: "not paired",
            // Off, and not "the default for this platform pair": live push to a
            // device that is not paired is not a setting, it is impossible.
            livePush: false,
            lastSyncedAt: nil
        )
    }

    /// Exchanges indexes with every live peer now rather than on the timer.
    public func syncNow() async -> ActionDocument {
        guard !links.isEmpty else { return .refused("no peers are paired with this device") }
        for link in links.values { await link.resync() }
        return .succeeded("asked \(links.count) peer\(links.count == 1 ? "" : "s") to sync")
    }
}
