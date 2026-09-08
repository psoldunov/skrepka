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
        let clips = listing.map(Self.clipDocument)
        let limited = limit == 0 ? clips : Array(clips.prefix(Int(limit)))
        return HistoryDocument(clips: limited, total: clips.count)
    }

    static func clipDocument(_ listing: SQLiteHistoryStore.ClipListing) -> ClipDocument {
        ClipDocument(
            contentHash: listing.contentHash,
            // `previewText` rather than `text`: it is what masks a concealed
            // entry, and the macOS picker's licence to list one does not extend
            // to printing a password manager's clip into a terminal and its
            // scrollback. Flattened and bounded here rather than in each
            // client, so a GNOME menu and `skrepka list` render the same string
            // and neither can be made to run an escape sequence.
            preview: SafeText.oneLine(listing.summary.previewText),
            kind: listing.summary.kind.rawValue,
            isPinned: listing.summary.isPinned,
            createdAt: listing.summary.createdAt,
            byteCount: listing.summary.byteCount,
            // Canonical media types, not the store's pasteboard identifiers: a
            // client outside this process has no business knowing that a Linux
            // store indexes by macOS type identifiers, which is an artefact of
            // one mapping table rather than a fact about the clipboard.
            representations: listing.representationTypes
                .compactMap(RepresentationKeyMap.canonical(forUTI:))
                .sorted()
        )
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
            livePush: await isLivePushOn(for: deviceID),
            lastSyncedAt: entry.lastSyncedAt
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

    // MARK: - Acting

    /// The clipboard targets an entry's stored representations can be written
    /// as, dropping any whose type identifier this build does not map.
    ///
    /// Split out of ``copy(_:)`` to keep that function inside the 40-line body
    /// the lint rule allows; it is pure, so it costs nothing to lift.
    private static func writableTargets(
        from representations: [String: Data]
    ) -> [String: Data] {
        var payloads: [RepresentationKey: Data] = [:]
        for (type, data) in representations {
            guard let key = RepresentationKeyMap.key(forUTI: type) else { continue }
            payloads[key] = data
        }
        return LinuxClipboardWriter.targets(for: payloads)
    }

    /// Puts one entry on the clipboard.
    public func copy(_ selector: ClipSelector) async -> ActionDocument {
        guard clipboard != nil else {
            return .refused(
                """
                There is no clipboard to write to in this session. \
                Run `skrepka doctor` to see what this session offers.
                """
            )
        }
        let listing: [SQLiteHistoryStore.ClipListing]
        do {
            listing = try await store.listing()
        } catch {
            // Surfaced rather than discarded: an empty listing here reads as
            // "there is nothing in the history yet", which is the one thing
            // this failure is not.
            return .refused("could not read the history: \(error)")
        }
        guard let entry = Self.resolve(selector, in: listing) else {
            return .refused(Self.notFound(selector, count: listing.count))
        }
        guard let contents = await store.contents(for: entry.summary.id) else {
            return .refused("that entry holds no bytes on this device yet", subject: entry.contentHash)
        }
        let targets = Self.writableTargets(from: contents.payload.representations)
        guard !targets.isEmpty else {
            return .refused(
                "nothing in that entry can be written to a Linux clipboard",
                subject: entry.contentHash
            )
        }
        // Re-bound here rather than relied on from the guard at the top: the
        // listing read and the contents read are both suspension points, and
        // `performStop()` clears `clipboard` between them. The optional chain
        // this replaces wrote nothing in that case and still answered
        // `.succeeded`, so `skrepka copy` printed "Copied." over an unchanged
        // clipboard.
        guard let clipboard else {
            return .refused(
                """
                The clipboard for this session went away while that entry was \
                being read, so nothing was copied. Try again.
                """,
                subject: entry.contentHash
            )
        }
        // Not paused around this one, unlike a live push: a copy the user asked
        // for is a copy, and hoisting it back to the top of the history is what
        // every clipboard manager does.
        await clipboard.setSelection(targets)
        return .succeeded(
            Self.copiedDetail(entry), subject: entry.contentHash)
    }

    static func resolve(
        _ selector: ClipSelector,
        in listing: [SQLiteHistoryStore.ClipListing]
    ) -> SQLiteHistoryStore.ClipListing? {
        switch selector {
        case .position(let index):
            guard index >= 1, index <= listing.count else { return nil }
            return listing[index - 1]
        case .hash(let prefix):
            let matches = listing.filter { $0.contentHash.hasPrefix(prefix) }
            // Exactly one, or nothing. A prefix that collides names unrelated
            // content and picking either pastes something nobody asked for.
            return matches.count == 1 ? matches.first : nil
        }
    }

    private static func notFound(_ selector: ClipSelector, count: Int) -> String {
        switch selector {
        case .position(let index):
            count == 0
                ? "there is nothing in the history yet"
                : "there is no entry \(index) — the history holds \(count)"
        case .hash(let prefix):
            "no single entry starts with \"\(prefix)\""
        }
    }

    /// Reads through the same masking and stripping the listing does: this
    /// string is printed straight into the terminal that asked for the copy.
    private static func copiedDetail(_ entry: SQLiteHistoryStore.ClipListing) -> String {
        "copied \(SafeText.oneLine(entry.summary.previewText, limit: 60))"
    }

    /// Exchanges indexes with every live peer now rather than on the timer.
    public func syncNow() async -> ActionDocument {
        guard !links.isEmpty else { return .refused("no peers are paired with this device") }
        for link in links.values { await link.resync() }
        return .succeeded("asked \(links.count) peer\(links.count == 1 ? "" : "s") to sync")
    }
}
