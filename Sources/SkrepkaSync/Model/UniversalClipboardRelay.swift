import Foundation

/// A file that Universal Clipboard staged on one Mac for a copy made on another,
/// and what happens when a peer sends one.
///
/// A copy that carries a file — a CleanShot screenshot does, a Finder copy is
/// one — goes to every nearby Mac signed into the same account. The receiving
/// Mac cannot have the original path, which exists only where the copy was
/// made, so macOS stages a fresh copy of the file under
/// `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/items/<UUID>/`,
/// with a new UUID on every relay.
///
/// A file-system entry is identified by its path — see `ClipItem.contentHash`
/// in `SkrepkaCore` — so Skrepka on the receiving Mac recorded each relay as a
/// file it had never seen: a second row for the same screenshot, attributed to
/// whatever was frontmost there (`loginwindow`, on a locked Mac), which sync
/// then carried back to the Mac the copy was made on. ``ClipboardHandoff`` and
/// ``RecentHashes`` cannot catch it, because both match exact hashes and a
/// relay's hash is new every time. It is not an echo of Skrepka's own write
/// either: the relay is of the user's copy, so marking sync writes
/// current-host-only left it untouched.
///
/// So a relay is history nowhere. Capture leaves it out, and a peer still on a
/// build that records relays has each one it sends discarded here and
/// tombstoned, which removes its own copy on its next sync. The Mac the copy
/// was made on records the real file and syncs that like anything else.
///
/// **The folder is an observation, not documentation.** Apple does not say
/// where Universal Clipboard stages files. This is the folder every relayed
/// row in a real two-Mac history on macOS 26 pointed into. It is matched by
/// three consecutive path components rather than by a whole path, so the
/// home folder does not matter. If a later macOS moves it, relays are recorded
/// again: the failure is a duplicate row, never a lost one.
public enum UniversalClipboardRelay {
    /// The staging folder, as the path components it is found by.
    static let stagingFolder = [
        "Group Containers", "group.com.apple.coreservices.useractivityd", "shared-pasteboard",
    ]

    /// The canonical key `public.file-url` crosses the wire under — see
    /// ``RepresentationKeyMap``, which a test holds this to.
    static let fileListKey = "text/uri-list"

    /// Whether `url` is a file Universal Clipboard staged on this machine.
    ///
    /// Something has to follow the folder: the folder itself is not a staged
    /// file.
    public static func isStaged(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let components = url.pathComponents
        let width = stagingFolder.count
        guard components.count > width else { return false }
        return (0..<(components.count - width)).contains { start in
            components[start..<(start + width)].elementsEqual(stagingFolder)
        }
    }

    /// Whether a copy holds files and every one of them is staged.
    ///
    /// Every rather than any: a copy that names one real file has something of
    /// its own worth keeping, and that is the conservative answer when two
    /// things disagree. Empty is false, because a copy that names no file is
    /// not a relayed one.
    public static func holdsOnlyStagedFiles(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy(isStaged)
    }

    /// `ClipKind` raw values of the file-system entries, which `SkrepkaSync`
    /// cannot name any other way. A test in `SkrepkaCore` holds this to
    /// `ClipKind.isFileSystemEntry`.
    static let fileSystemKinds: Set<String> = ["file", "folder", "imageFile"]

    /// Whether the bytes a peer sent for an item show it to be a relay.
    ///
    /// Only bytes can say: the metadata of an item names its files by display
    /// name alone. So an item that arrives without them — a live push over the
    /// inline limit, or an index entry — is stored as usual and judged when
    /// its bytes are fetched.
    ///
    /// Only a file-system entry, as at capture. Its hash is its path, so the
    /// tombstone ``discarding(_:by:at:)`` writes can only ever remove the
    /// relay. Any other kind hashes its content — rich text outranks a file
    /// URL, so a relay carrying both is rich text — and that hash is the
    /// original's too: the tombstone would remove the user's own copy on
    /// every device.
    public static func isRelay(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) -> Bool {
        guard fileSystemKinds.contains(meta.kind) else { return false }
        let lists = payloads.filter { $0.key.canonical == fileListKey }.map(\.value)
        return !lists.isEmpty && lists.allSatisfy { holdsOnlyStagedFiles(fileURLs(in: $0)) }
    }

    /// What discarding a relay a peer sent comes to.
    ///
    /// The row goes if it has landed — an index entry lands before its bytes
    /// do — and a tombstone keeps it gone. Without one, the peer would offer it
    /// again on the next exchange, the merge would learn it again, and the
    /// bytes would be fetched again only to be thrown away every time. The
    /// tombstone also crosses to the peer, whose own row it removes.
    ///
    /// Stamped no earlier than the item was created. ``MergeEngine`` lets
    /// content created after a tombstone win, so a tombstone read off a clock
    /// behind the sender's would lose to the very item it removes, and the
    /// next exchange would bring the relay straight back.
    public static func discarding(
        _ meta: SyncClipMeta,
        by deviceID: SyncDeviceID,
        at now: Date
    ) -> [MergeAction] {
        [
            .deleteLocally(contentHash: meta.contentHash),
            .recordTombstone(
                Tombstone(
                    contentHash: meta.contentHash,
                    deletedAt: max(now, meta.createdAt),
                    deviceID: deviceID
                )
            ),
        ]
    }

    /// The URLs one file-list representation names, or none if it is not UTF-8
    /// or any line is not a URL.
    ///
    /// A Mac sends `public.file-url` as a single URL. A Linux peer sends
    /// `text/uri-list`: a URL per line and `#` for a comment (RFC 2483). Both
    /// read the same way here. A line that is not a URL makes the whole list
    /// unreadable, not just one entry shorter, because a list read partly is
    /// the list that would call a copy staged when it is not.
    static func fileURLs(in data: Data) -> [URL] {
        guard let text = String(bytes: data, encoding: .utf8) else { return [] }
        let lines =
            text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: ignoredCharacters) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let urls = lines.compactMap { URL(string: $0) }
        return urls.count == lines.count ? urls : []
    }

    /// Whitespace, and the NUL an app sometimes leaves at the end of a URL it
    /// wrote as a C string.
    private static let ignoredCharacters = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))
}

// MARK: - Discarding

extension HistoryStoring {
    /// Discards a relay a peer sent — see ``UniversalClipboardRelay``.
    ///
    /// Through ``applyRemote(_:)`` because that is the one method that deletes
    /// by hash, and a plan is idempotent: discarding a relay twice, or one that
    /// never landed, leaves the store where discarding it once would.
    func discardRelay(_ meta: SyncClipMeta, by deviceID: SyncDeviceID, at now: Date) async throws {
        try await applyRemote(UniversalClipboardRelay.discarding(meta, by: deviceID, at: now))
    }
}
