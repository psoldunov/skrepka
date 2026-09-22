import Foundation
import Logging
import SkrepkaCore
import SkrepkaIPC
import SkrepkaSync

extension Daemon {
    /// Searches full stored text, preserving the scorer's ranking rather than
    /// re-ranking the flattened previews a client happens to display.
    public func searchDocument(query: String, limit: UInt32) async -> HistoryDocument {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return await historyDocument(limit: limit)
        }
        guard let listing = await readHistoryListing() else {
            return HistoryDocument(clips: [], total: 0)
        }
        let byID = Dictionary(listing.map { ($0.summary.id, $0) }) { first, _ in first }
        let matched = Matcher().filter(listing.map(\.summary), query: query)
        let local = await localDeviceHex(ifAnyOf: listing)
        let fileLimit = settings.fileSync.maximumBytes
        let clips = matched.compactMap { byID[$0.id] }.map {
            Self.clipDocument($0, localDeviceHex: local, fileLimit: fileLimit)
        }
        let limited = limit == 0 ? clips : Array(clips.prefix(Int(limit)))
        return HistoryDocument(clips: limited, total: clips.count)
    }

    /// Copies with the requested wire style, refusing an unknown style before
    /// it could silently turn a plain-text request into a rich copy.
    public func copyAs(_ selector: ClipSelector, style: String) async -> ActionDocument {
        guard let style = CopyStyle(wireValue: style) else {
            return .refused("unknown copy style \"\(style)\"")
        }
        switch style {
        case .rich: return await copy(selector)
        case .plain:
            return await copy(
                selector,
                targetBuilder: \.plainTargets,
                emptyTargetDetail: "that entry has no text to copy as plain text"
            )
        }
    }

    /// Pins or unpins an entry only when its state differs, so an idempotent
    /// command does not create a newer sync register write for the same value.
    public func setPinned(_ selector: ClipSelector, pinned: Bool) async -> ActionDocument {
        guard let listing = await readHistoryListing() else {
            return .refused("could not read the history")
        }
        guard let entry = Self.resolve(selector, in: listing) else {
            return .refused(Self.notFound(selector, count: listing.count))
        }
        do {
            try await store.setPinned(entry.summary.id, to: pinned)
        } catch {
            return .refused("could not pin: \(error)")
        }
        notifyHistoryChanged()
        return .succeeded(pinned ? "pinned" : "unpinned", subject: entry.contentHash)
    }

    /// Deletes one resolved entry; the store writes its sync tombstone with it.
    public func delete(_ selector: ClipSelector) async -> ActionDocument {
        guard let listing = await readHistoryListing() else {
            return .refused("could not read the history")
        }
        guard let entry = Self.resolve(selector, in: listing) else {
            return .refused(Self.notFound(selector, count: listing.count))
        }
        do {
            try await store.deleteChecked(entry.summary.id)
        } catch {
            return .refused("could not delete: \(error)")
        }
        notifyHistoryChanged()
        return .succeeded("deleted", subject: entry.contentHash)
    }

    /// Clears the requested subset and reports the rows SQLite removed.
    public func clear(keepingPinned: Bool) async -> ActionDocument {
        let count: Int
        do {
            count = try await store.clearChecked(keepingPinned: keepingPinned)
        } catch {
            return .refused("could not clear: \(error)")
        }
        notifyHistoryChanged()
        return .succeeded("cleared \(count) entr\(count == 1 ? "y" : "ies")")
    }

    /// Returns one entry's picture, capped before base64 expands it onto the
    /// session bus. A peer-only index has no payload and answers unavailable.
    ///
    /// Bytes the entry holds come first — a picture stored as itself, or the
    /// one file of its bundle, which is the copy as it was. Only a picture file
    /// copied on this device with neither is read off disk, now.
    public func preview(_ selector: ClipSelector, maxBytes: UInt32) async -> PreviewDocument {
        guard let listing = await readHistoryListing() else {
            return .unavailable("could not read the history", contentHash: selector.wireValue)
        }
        guard let entry = Self.resolve(selector, in: listing) else {
            return .unavailable(
                Self.notFound(selector, count: listing.count), contentHash: selector.wireValue)
        }
        guard !entry.summary.isConcealed else {
            return .unavailable("that entry is concealed", contentHash: entry.contentHash)
        }
        guard let contents = await store.contents(for: entry.summary.id) else {
            return .unavailable("that entry has no bytes on this device yet", contentHash: entry.contentHash)
        }
        let limit = Int(
            min(
                maxBytes == 0 ? UInt32(PreviewDocument.defaultByteLimit) : maxBytes,
                UInt32(PreviewDocument.defaultByteLimit)))
        guard let picture = Self.heldPicture(in: contents.payload.representations) else {
            return await previewFromDisk(entry, fileURLs: contents.fileURLs, limit: limit)
        }
        guard picture.bytes.count <= limit else {
            return .unavailable(
                "too large to preview", contentHash: entry.contentHash, byteCount: picture.bytes.count)
        }
        return .picture(picture.bytes, mediaType: picture.mediaType, contentHash: entry.contentHash)
    }

    /// The picture file a row copied here names, read when the row is drawn —
    /// what a copy with no bundle previews from, since the daemon keeps no
    /// thumbnail and the file-size limit may have kept no bytes.
    ///
    /// Never a row from another device: its path is one on the machine that
    /// made the copy, and whatever this one keeps there is not that picture.
    private func previewFromDisk(
        _ entry: SQLiteHistoryStore.ClipListing,
        fileURLs: [URL],
        limit: Int
    ) async -> PreviewDocument {
        let hash = entry.contentHash
        let local = await localDeviceHex(ifAnyOf: [entry])
        guard entry.summary.kind == .imageFile, fileURLs.count == 1, let url = fileURLs.first,
            !Self.isForeign(origin: entry.originDeviceID, local: local)
        else { return .unavailable("that entry has no picture to preview", contentHash: hash) }
        switch await ImageFileProbe.picture(atFileURL: url, limit: limit) {
        case .picture(let format, let bytes):
            return .picture(bytes, mediaType: format.mediaType, contentHash: hash)
        case .tooLarge:
            return .unavailable("too large to preview", contentHash: hash)
        case .unavailable:
            return .unavailable("the copied picture is gone or can no longer be read", contentHash: hash)
        }
    }

    private func readHistoryListing() async -> [SQLiteHistoryStore.ClipListing]? {
        do {
            return try await store.listing()
        } catch {
            logger.error(
                "could not read the history for a client",
                metadata: [
                    "error": .string(String(describing: error))
                ])
            return nil
        }
    }

    /// A picture the entry holds itself: stored as a picture, or failing that
    /// the one file of its bundle, in any format a GTK client draws.
    private static func heldPicture(in representations: [String: Data]) -> (mediaType: String, bytes: Data)? {
        if let picture = picture(in: representations) { return picture }
        return ImageFileProbe.bundledPicture(in: representations).map {
            ($0.header.format.mediaType, $0.bytes)
        }
    }

    private static func picture(in representations: [String: Data]) -> (mediaType: String, bytes: Data)? {
        for mediaType in previewMediaTypes {
            guard
                let type = representations.keys.first(where: {
                    RepresentationKeyMap.canonical(forUTI: $0) == mediaType
                }), let bytes = representations[type]
            else { continue }
            return (mediaType, bytes)
        }
        return nil
    }
}
