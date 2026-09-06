import Foundation

@testable import SkrepkaSync

/// A ``HistoryStoring`` backed by two dictionaries.
///
/// Exists because `SkrepkaSync` cannot import `SkrepkaCore` — the real store
/// does not build on Linux, and the loopback test is the same test on both
/// platforms. Applies merge plans faithfully enough for the phase's proof:
/// inserts, bumps, pins and deletions all land.
actor FakeHistoryStore: HistoryStoring {
    private var items: [String: SyncClipMeta]
    private var deletions: [String: Tombstone]
    private var payloads: [String: [RepresentationKey: Data]]

    init(
        items: [SyncClipMeta] = [],
        tombstones: [Tombstone] = [],
        payloads: [String: [RepresentationKey: Data]] = [:]
    ) {
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.contentHash, $0) })
        deletions = Dictionary(uniqueKeysWithValues: tombstones.map { ($0.contentHash, $0) })
        self.payloads = payloads
    }

    /// Strictly after the cursor, which is what `HistoryStoring` states and
    /// what all three real engines do. This fake was inclusive until
    /// ``HistoryStoringContractTests`` ran the same assertion against it and the
    /// probe store — which is exactly what a shared suite is for.
    func syncIndex(since cursor: Date?) -> [SyncClipMeta] {
        items.values
            .filter { item in !item.isConcealed && (cursor.map { item.createdAt > $0 } ?? true) }
            .sorted { $0.contentHash < $1.contentHash }
    }

    func tombstones(since cursor: Date?) -> [Tombstone] {
        deletions.values
            .filter { tombstone in cursor.map { tombstone.deletedAt > $0 } ?? true }
            .sorted { $0.contentHash < $1.contentHash }
    }

    func recordTombstone(_ tombstone: Tombstone) {
        deletions[tombstone.contentHash] =
            deletions[tombstone.contentHash]?.merged(with: tombstone) ?? tombstone
    }

    /// Concealed content is filtered here as well as in ``syncIndex(since:)``.
    ///
    /// Both, because a `contentHash` names content without carrying it: a peer
    /// can ask for one it was never offered, and the real stores hash content
    /// unsalted, so a non-nil answer confirms a guess as well as serving it.
    /// `HistoryStoring` states the rule for every conformance, and a fake that
    /// broke it would let a test encode the wrong contract.
    func payload(for contentHash: String, key: RepresentationKey) -> Data? {
        guard items[contentHash]?.isConcealed != true else { return nil }
        return payloads[contentHash]?[key]
    }

    /// Bytes already held are kept. A peer can name content this device
    /// captured itself, so an offer that overwrote would let it substitute its
    /// own bytes under a hash that still matches the original — see
    /// ``HistoryStoring/capture(_:payloads:)``.
    func capture(_ meta: SyncClipMeta, payloads newPayloads: [RepresentationKey: Data]) {
        items[meta.contentHash] = items[meta.contentHash]?.combining(meta) ?? meta
        payloads[meta.contentHash, default: [:]].merge(newPayloads) { held, _ in held }
    }

    func applyRemote(_ actions: [MergeAction]) {
        for action in actions {
            apply(action)
        }
    }

    private func apply(_ action: MergeAction) {
        switch action {
        case .insert(let meta):
            items[meta.contentHash] = items[meta.contentHash]?.combining(meta) ?? meta
        case .bumpCreatedAt(let contentHash, let date):
            items[contentHash] = items[contentHash].map { bumped($0, to: date) }
        case .applyPin(let contentHash, let register):
            items[contentHash] = items[contentHash].map { pinned($0, register) }
        case .deleteLocally(let contentHash):
            items[contentHash] = nil
            payloads[contentHash] = nil
        case .recordTombstone(let tombstone):
            recordTombstone(tombstone)
        case .dropTombstone(let contentHash):
            // The graveyard is pruned, not merely ignored: a store that keeps
            // expired rows reads them back into every later merge only to
            // discard them again.
            deletions[contentHash] = nil
        }
    }

    private func bumped(_ meta: SyncClipMeta, to createdAt: Date) -> SyncClipMeta {
        rebuilt(meta, createdAt: createdAt, isPinned: meta.isPinned)
    }

    private func pinned(_ meta: SyncClipMeta, _ register: LWWRegister<Bool>) -> SyncClipMeta {
        rebuilt(meta, createdAt: meta.createdAt, isPinned: register)
    }

    private func rebuilt(
        _ meta: SyncClipMeta,
        createdAt: Date,
        isPinned: LWWRegister<Bool>
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: meta.contentHash,
            kind: meta.kind,
            preview: meta.preview,
            createdAt: createdAt,
            isPinned: isPinned,
            isConcealed: meta.isConcealed,
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            sourceBundleID: meta.sourceBundleID,
            originDeviceID: meta.originDeviceID,
            representations: meta.representations
        )
    }
}
