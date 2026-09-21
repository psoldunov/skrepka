import Foundation

@testable import SkrepkaSync

/// A store behaving the way a 0.2 build's does when offered a file bundle: it
/// has no type to keep one under, so it drops the representation on the way
/// in — descriptor and bytes both — and keeps everything else.
///
/// Counts the captures that brought bytes, which is how a test sees a peer
/// fetching the same thing again.
actor OldPeerStore: HistoryStoring {
    private let inner = FakeHistoryStore()
    private(set) var capturesWithBytes = 0

    func syncIndex(since cursor: Date?) async -> [SyncClipMeta] {
        await inner.syncIndex(since: cursor)
    }

    func applyRemote(_ actions: [MergeAction]) async {
        await inner.applyRemote(
            actions.map { action in
                guard case .insert(let meta) = action else { return action }
                return .insert(CapabilityFilter.none.meta(meta))
            }
        )
    }

    func tombstones(since cursor: Date?) async -> [Tombstone] {
        await inner.tombstones(since: cursor)
    }

    func recordTombstone(_ tombstone: Tombstone) async {
        await inner.recordTombstone(tombstone)
    }

    func payload(for contentHash: String, key: RepresentationKey) async -> Data? {
        await inner.payload(for: contentHash, key: key)
    }

    func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async {
        if !payloads.isEmpty { capturesWithBytes += 1 }
        let filter = CapabilityFilter.none
        await inner.capture(filter.meta(meta), payloads: filter.payloads(payloads))
    }
}

/// Every item an exchange or a link handed on, in order.
actor FetchedItems {
    private(set) var items: [(meta: SyncClipMeta, payloads: [RepresentationKey: Data])] = []

    nonisolated func record(_ meta: SyncClipMeta, _ payloads: [RepresentationKey: Data]) async {
        await append(meta, payloads)
    }

    private func append(_ meta: SyncClipMeta, _ payloads: [RepresentationKey: Data]) {
        items.append((meta, payloads))
    }

    func hashes() -> [String] { items.map(\.meta.contentHash) }
}

enum FileSyncFixtures {
    static let fileURLKey = RepresentationKey(canonical: "text/uri-list", origin: "public.file-url")

    /// A file copy as a 0.3 sender stores it: the path, and the bundle.
    static func fileItem(
        _ contentHash: String,
        bundle: Data,
        deviceID: SyncDeviceID,
        at date: Date
    ) -> (meta: SyncClipMeta, payloads: [RepresentationKey: Data]) {
        let payloads: [RepresentationKey: Data] = [
            fileURLKey: Data("file:///Users/someone/Desktop/shot.png".utf8),
            FileBundle.key: bundle,
        ]
        let meta = SyncClipMeta(
            contentHash: contentHash,
            kind: "file",
            preview: "shot.png",
            createdAt: date,
            isPinned: LWWRegister(value: false, timestamp: date, deviceID: deviceID),
            originDeviceID: deviceID,
            representations: payloads.map { RepresentationDescriptor(key: $0.key, byteCount: $0.value.count) }
        )
        return (meta, payloads)
    }

    static func bundle(byteCount: Int = 16) throws -> Data {
        let file = FileBundle.File(name: "shot.png", bytes: Data(repeating: 7, count: byteCount))
        return try FileBundle(files: [file]).encoded()
    }
}
