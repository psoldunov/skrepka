import Foundation
import SkrepkaSync

/// A ``HistoryStoring`` backed by one JSON file.
///
/// The second conformance of that protocol outside a test, and the reason it is
/// worth having: a protocol with one implementation is a guess that compiles,
/// and every rule `HistoryStoring` states — concealed content filtered on *both*
/// paths, an idempotent merge plan, a nil payload as an ordinary answer — is a
/// rule this had to be written to satisfy rather than one the store it was
/// extracted from happened to satisfy already.
///
/// JSON on purpose. It is the format a person debugging a failed runbook step
/// can read with `cat`, and this store exists to make a failure legible rather
/// than to be fast. Nothing here is a model for the Linux daemon, which has
/// SQLite (D-3).
///
/// An actor: the responder, the link and the command loop all reach it, and none
/// of them is on the same isolation domain.
public actor ProbeStore: HistoryStoring {
    /// One item, exactly as the wire describes it plus whatever bytes are held.
    ///
    /// The wire shape is the storage shape here, which is the one place that is
    /// the right answer: this store's whole job is to be a peer, so a mapping
    /// layer between the two would be a second thing that can be wrong.
    struct Entry: Codable, Sendable {
        var meta: SyncClipMeta
        /// Keyed by ``RepresentationKey/canonical``, because a `Codable`
        /// dictionary needs a string key and the canonical media type is the
        /// one both platforms agree on.
        var payloads: [String: Data]
    }

    private struct Contents: Codable, Sendable {
        var items: [String: Entry] = [:]
        var tombstones: [String: Tombstone] = [:]
        var peers: [String: StoredPeer] = [:]
    }

    /// A paired peer as this store keeps it: the wire record, plus the two
    /// per-peer facts `PairedDeviceStoring` holds beside it.
    struct StoredPeer: Codable, Sendable {
        var certificateDER: Data
        var deviceName: String
        var platform: String
        var pairedAt: Date
        var highestProtocolSeen: Int?
        var livePushChoice: String?
    }

    private let url: URL
    private var contents: Contents

    /// The peer table, for the `PairedDeviceStoring` half in
    /// `ProbeStore+Pairing.swift`. Internal rather than private: Swift scopes
    /// `private` to the file, and that extension is the other half of this type.
    var storedPeers: [String: StoredPeer] {
        get { contents.peers }
        set { contents.peers = newValue }
    }

    /// Writes the file, for the same extension.
    func persist() throws { try save() }

    /// Opens or creates the file.
    ///
    /// A store whose file will not parse is refused rather than silently
    /// replaced: the runbook's whole value is that a surprising result is worth
    /// investigating, and quietly starting over destroys the evidence.
    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            contents = Contents()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.write(Contents(), to: url)
            return
        }
        contents = try JSONDecoder().decode(Contents.self, from: try Data(contentsOf: url))
    }

    // MARK: - HistoryStoring

    /// Never includes concealed content, and never includes an item the store
    /// holds no bytes for.
    ///
    /// The second half is `SyncClipMeta`'s rule about representation lists: a
    /// list is a claim about what its owner can serve, so an item learned from a
    /// peer and not yet fetched is offered promising nothing.
    public func syncIndex(since cursor: Date?) -> [SyncClipMeta] {
        contents.items.values
            .filter { entry in
                guard !entry.meta.isConcealed else { return false }
                guard let cursor else { return true }
                return entry.meta.createdAt > cursor
            }
            .map(Self.servable)
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func tombstones(since cursor: Date?) -> [Tombstone] {
        contents.tombstones.values
            .filter { tombstone in
                guard let cursor else { return true }
                return tombstone.deletedAt > cursor
            }
            .sorted { $0.deletedAt > $1.deletedAt }
    }

    public func recordTombstone(_ tombstone: Tombstone) throws {
        merge(tombstone)
        try save()
    }

    /// Nil for content this store does not hold, and for concealed content.
    ///
    /// Both, for the reason the protocol gives: a `contentHash` names content
    /// without carrying it, so a peer can ask for one it was never offered, and
    /// a non-nil answer would confirm a guess as well as serve it.
    public func payload(for contentHash: String, key: RepresentationKey) -> Data? {
        guard let entry = contents.items[contentHash], !entry.meta.isConcealed else { return nil }
        return entry.payloads[key.canonical]
    }

    /// Records an item learned from a peer.
    ///
    /// **Refuses concealed content**, the receiving half of D-7. Identity is
    /// `contentHash`, so a second offer of content already held adds no second
    /// entry — it fills in bytes that were missing, and leaves bytes that were
    /// not alone, so a peer cannot overwrite what this store captured itself.
    public func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws {
        guard !meta.isConcealed else { return }
        var entry =
            contents.items[meta.contentHash]
            ?? Entry(meta: meta, payloads: [:])
        entry.meta = entry.meta.combining(meta)
        for (key, data) in payloads where entry.payloads[key.canonical] == nil {
            entry.payloads[key.canonical] = data
        }
        contents.items[meta.contentHash] = entry
        try save()
    }

    public func applyRemote(_ actions: [MergeAction]) throws {
        for action in actions {
            apply(action)
        }
        try save()
    }

    // MARK: - Local edits, for the runbook

    /// Records something copied on this peer.
    @discardableResult
    public func add(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) throws -> Bool {
        let isNew = contents.items[meta.contentHash] == nil
        var entry = contents.items[meta.contentHash] ?? Entry(meta: meta, payloads: [:])
        entry.meta = isNew ? meta : entry.meta.combining(meta)
        for (key, data) in payloads {
            entry.payloads[key.canonical] = data
        }
        contents.items[meta.contentHash] = entry
        try save()
        return isNew
    }

    /// Flips a pin and stamps the register that carries it to peers.
    ///
    /// Writing the flag without the register is the mistake the real store
    /// documents: the pin would never win a merge and the change would silently
    /// fail to propagate.
    public func setPin(
        _ isPinned: Bool,
        contentHash: String,
        deviceID: SyncDeviceID,
        at now: Date
    ) throws -> Bool {
        guard var entry = contents.items[contentHash] else { return false }
        entry.meta = Self.repinned(entry.meta, isPinned: isPinned, deviceID: deviceID, at: now)
        contents.items[contentHash] = entry
        try save()
        return true
    }

    /// Deletes, and writes the tombstone that stops the next sync bringing it
    /// back.
    public func delete(contentHash: String, deviceID: SyncDeviceID, at now: Date) throws -> Bool {
        guard let entry = contents.items.removeValue(forKey: contentHash) else { return false }
        if !entry.meta.isConcealed {
            merge(Tombstone(contentHash: contentHash, deletedAt: now, deviceID: deviceID))
        }
        try save()
        return true
    }

    /// Everything held, concealed items included, for `dump`.
    public func everything() -> [SyncClipMeta] {
        contents.items.values.map(\.meta).sorted { $0.createdAt > $1.createdAt }
    }

    /// The bytes held for one item, keyed canonically.
    public func heldPayloads(for contentHash: String) -> [RepresentationKey: Data] {
        var held: [RepresentationKey: Data] = [:]
        for (canonical, data) in contents.items[contentHash]?.payloads ?? [:] {
            held[RepresentationKey(canonical: canonical)] = data
        }
        return held
    }

    // MARK: - Internals

    /// The item as a peer is allowed to see it: only the representations this
    /// store actually holds bytes for.
    private static func servable(_ entry: Entry) -> SyncClipMeta {
        let held = entry.meta.representations.filter { entry.payloads[$0.key.canonical] != nil }
        guard held.count != entry.meta.representations.count else { return entry.meta }
        return rebuilt(entry.meta, representations: held)
    }

    private func merge(_ tombstone: Tombstone) {
        contents.tombstones[tombstone.contentHash] =
            contents.tombstones[tombstone.contentHash]?.merged(with: tombstone) ?? tombstone
    }

    private func apply(_ action: MergeAction) {
        switch action {
        case .insert(let meta):
            // Concealed content never crosses the wire, so a plan that carries
            // some is a peer misbehaving rather than a case to honour.
            guard !meta.isConcealed else { return }
            contents.items[meta.contentHash] =
                contents.items[meta.contentHash].map { held in
                    Entry(meta: held.meta.combining(meta), payloads: held.payloads)
                } ?? Entry(meta: meta, payloads: [:])
        case .deleteLocally(let contentHash):
            contents.items[contentHash] = nil
        case .recordTombstone(let tombstone):
            merge(tombstone)
        case .dropTombstone(let contentHash):
            // The graveyard is pruned rather than merely ignored: a store that
            // keeps expired rows reads them into every later merge only to
            // discard them again.
            contents.tombstones[contentHash] = nil
        case .bumpCreatedAt(let contentHash, let date):
            edit(contentHash) { Self.rebuilt($0, createdAt: date) }
        case .applyPin(let contentHash, let register):
            edit(contentHash) { Self.rebuilt($0, isPinned: register) }
        }
    }

    /// Rewrites one item's metadata, or does nothing when it is not held.
    private func edit(_ contentHash: String, _ change: (SyncClipMeta) -> SyncClipMeta) {
        guard var entry = contents.items[contentHash] else { return }
        entry.meta = change(entry.meta)
        contents.items[contentHash] = entry
    }

    private func save() throws {
        try Self.write(contents, to: url)
    }

    /// Written atomically, so a crash mid-write leaves the previous store rather
    /// than half of the new one.
    ///
    /// `Data.write(options: .atomic)` rather than a hand-rolled write-and-replace:
    /// it already writes to a sibling and renames, and it does so on both
    /// platforms. `FileManager.replaceItemAt` does not — on swift-corelibs
    /// Foundation it refuses a destination that is not there, which is every
    /// first write.
    private static func write(_ contents: Contents, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(contents).write(to: url, options: .atomic)
    }
}
