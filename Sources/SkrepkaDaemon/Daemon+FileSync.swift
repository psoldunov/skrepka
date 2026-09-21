import Foundation
import Logging
import SkrepkaCore
import SkrepkaSync

// Files copied on another device, and what this daemon puts on the clipboard
// for them.
//
// A file row from another machine names paths that exist only there. Written
// here as it arrived, Dolphin pasted "/Users/…/CleanShot … .png does not
// exist". So every write of a row — a live push, `skrepka copy`, the picker's
// `CopyAs` — goes through ``clipboardWrite(for:)``, which asks
// `ForeignFileGuard` and never hands a foreign path to the clipboard.
extension Daemon {
    /// Where files received from peers are written. See `DaemonOptions.fileCacheRoot`.
    ///
    /// `nonisolated` because it is derived from two `let`s and reads no state.
    nonisolated var fileCache: FileCache {
        FileCache(root: options.fileCacheRoot(environment: environment))
    }

    /// Hands the store its cache, so deleting a row removes its files, and
    /// removes whatever a crash or an older build left behind.
    func startFileCache() async {
        await store.setFileCache(fileCache)
        let removed = await store.sweepFileCache()
        if removed > 0 {
            logger.info(
                "removed files received for rows that no longer exist",
                metadata: ["count": .stringConvertible(removed)])
        }
    }

    /// This device's identity as the store records it in `origin_device_id`,
    /// or nil when there is none and none can be made.
    ///
    /// The store's copy is set only while sync runs; with sync off the rows
    /// from an earlier run still carry the device's own hex, and reading it
    /// from the key file is what keeps them local.
    func localDeviceHex() async -> String? {
        if let deviceID = await store.localDeviceID { return deviceID.hex }
        do {
            return try await trust.localIdentity().deviceID.hex
        } catch {
            logger.error(
                "could not read this device's identity; treating every synced file row as foreign",
                metadata: ["error": .string(String(describing: error))])
            return nil
        }
    }

    /// ``localDeviceHex()``, asked only when a row records an origin at all —
    /// a history with none needs no answer, and a daemon that has never run
    /// sync should not make itself a key to find that out.
    func localDeviceHex(ifAnyOf listing: [SQLiteHistoryStore.ClipListing]) async -> String? {
        guard listing.contains(where: { $0.originDeviceID != nil }) else { return nil }
        return await localDeviceHex()
    }

    /// Whether a row with this origin was recorded by another device.
    ///
    /// A row with no origin was recorded here before this device had an
    /// identity. When this device's own identity is unknown, any origin is
    /// foreign — the safe side: a local file row pastes as its names, where
    /// the other answer pastes a path that does not exist.
    static func isForeign(origin: String?, local: String?) -> Bool {
        guard let origin else { return false }
        return origin != local
    }

    /// What one row puts on the clipboard. Materialises a foreign row's files
    /// first, off this actor.
    func clipboardWrite(for source: WritableRow) async -> ClipboardWrite {
        let decision = ForeignFileGuard.decide(
            kind: source.kind,
            representations: source.representations,
            preview: source.preview,
            isForeign: source.isForeign
        )
        switch decision {
        case .passThrough:
            let files = source.kind.isFileSystemEntry && !source.isForeign ? source.fileURLs : []
            return ClipboardWrite(representations: source.representations, fileURLs: files)
        case .files(let bundle):
            do {
                let urls = try await Self.materialize(bundle, contentHash: source.contentHash, in: fileCache)
                return ClipboardWrite(ForeignFileGuard.clipboard(forFilesAt: urls, from: bundle))
            } catch {
                logger.error(
                    "could not write received files; pasting their names instead",
                    metadata: ["error": .string(String(describing: error))])
                let names = bundle.files.map { SafeFileName.sanitized($0.name) }
                return ClipboardWrite(ForeignFileGuard.clipboard(forNames: names.joined(separator: "\n")))
            }
        case .names(let text):
            return ClipboardWrite(ForeignFileGuard.clipboard(forNames: text))
        }
    }

    /// Up to 32 MB of writes on a first paste, so never on the actor.
    @concurrent
    nonisolated static func materialize(
        _ bundle: FileBundle,
        contentHash: String,
        in cache: FileCache
    ) async throws -> [URL] {
        try FileMaterializer.materialize(bundle, contentHash: contentHash, in: cache)
    }
}
