import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// Every history store this build has, as one interchangeable surface.
///
/// Wider than `SkrepkaSync.HistoryStoring` on purpose. That protocol is the
/// narrowest view a *transport* needs; `HistoryStoringTests` also has to drive
/// local capture, pinning, deletion and retention, because most of what the
/// protocol promises — that eviction writes no tombstone, that a deletion does —
/// is only observable from the other side of those.
///
/// Every requirement is `async`: `HistoryStore` is `@MainActor` and
/// `SQLiteHistoryStore` is an `actor`, and an isolated synchronous method
/// witnesses an `async` requirement, so both conform without a forwarding shim
/// except where the two genuinely name the same thing differently.
protocol HistoryStoreConforming: Sendable {
    /// Newest first, pinned entries hoisted. `HistoryStore` publishes this as
    /// `items` for SwiftUI; the Linux store computes it on demand because there is
    /// nothing there to publish to.
    func summaries() async throws -> [ClipSummary]

    /// This device's sync identity. A store starts without one when the sync
    /// stack has not loaded a certificate yet, and gains one later — the case
    /// `anEntryWithNoOptionalColumnsSetReadsBackAsNil` needs both halves of.
    func setLocalDeviceID(_ deviceID: SyncDeviceID?) async

    @discardableResult func capture(_ item: ClipItem) async -> Bool
    func contents(for id: UUID) async -> ClipContents?
    func togglePin(_ id: UUID) async
    func delete(_ id: UUID) async
    func clear(keepingPinned: Bool) async

    func syncIndex(since cursor: Date?) async throws -> [SyncClipMeta]
    func applyRemote(_ actions: [MergeAction]) async throws
    func tombstones(since cursor: Date?) async throws -> [Tombstone]
    func recordTombstone(_ tombstone: Tombstone) async throws

    /// Housekeeping `HistoryStoring` never asks for, because a transport has no
    /// business scheduling it — but both engines have to do it and both have to
    /// let go of a record at the same instant, which is only assertable from a
    /// suite that drives them side by side. `asOf` is explicit for the reason
    /// `MergeInput.now` is: a ninety-day window is untestable against a clock.
    func pruneExpiredTombstones(asOf now: Date) async throws
    func payload(for contentHash: String, key: RepresentationKey) async throws -> Data?
    func capture(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async throws

    func pairedPeers() async throws -> [PairedPeer]
    func pairedPeer(_ deviceID: SyncDeviceID) async throws -> PairedPeer?
    func savePairedPeer(_ peer: PairedPeer) async throws
    func forgetPairedPeer(_ deviceID: SyncDeviceID) async throws
    func highestProtocolVersion(for deviceID: SyncDeviceID) async throws -> ProtocolVersion?
    func recordProtocolVersion(_ version: ProtocolVersion, for deviceID: SyncDeviceID) async throws
    func livePushChoice(for deviceID: SyncDeviceID) async throws -> LivePushChoice
    func setLivePushChoice(_ choice: LivePushChoice, for deviceID: SyncDeviceID) async throws
}

// MARK: - Conformances

#if canImport(SwiftData)

    /// `nonisolated` rather than the conformance `InferIsolatedConformances` would
    /// infer for a `@MainActor` type: ``HistoryStoreConforming`` refines `Sendable`
    /// and an isolated conformance cannot satisfy that. The witnesses stay
    /// main-actor; only the conformance is not.
    extension HistoryStore: nonisolated HistoryStoreConforming {
        func summaries() -> [ClipSummary] { items }

        func setLocalDeviceID(_ deviceID: SyncDeviceID?) { localDeviceID = deviceID }
    }

#endif

#if os(Linux)

    extension SQLiteHistoryStore: HistoryStoreConforming {}

#endif

// MARK: - Engines

/// One conformance, and how to build a fresh empty one.
///
/// The suite is parameterised over these rather than over a list of types so a
/// platform that has only one engine runs the same assertions against the one it
/// has, instead of the suite being skipped there.
struct HistoryStoreEngine: Sendable, CustomTestStringConvertible {
    let name: String
    let make: @Sendable (RetentionPolicy, SyncDeviceID?) async throws -> any HistoryStoreConforming

    var testDescription: String { name }

    /// Every engine available on this platform. Two would mean a build that has
    /// both, which no platform does today: macOS resolves no `CSQLite` and Linux
    /// has no SwiftData.
    static let all: [HistoryStoreEngine] = {
        var engines: [HistoryStoreEngine] = []
        #if canImport(SwiftData)
            engines.append(
                HistoryStoreEngine(name: "SwiftData") { retention, deviceID in
                    try await MainActor.run {
                        let store = try HistoryStore(location: nil, retention: retention)
                        store.localDeviceID = deviceID
                        return store
                    }
                }
            )
        #endif
        #if os(Linux)
            engines.append(
                HistoryStoreEngine(name: "SQLite") { retention, deviceID in
                    try SQLiteHistoryStore(
                        location: nil,
                        retention: retention,
                        localDeviceID: deviceID
                    )
                }
            )
        #endif
        return engines
    }()
}

// MARK: - Fixtures

/// Values both engines are driven with.
///
/// Separate from `SyncFixtures`, which builds a `HistoryStore` directly and is
/// fenced to SwiftData with the suites that use it.
enum EngineFixtures {
    static let localDevice = SyncDeviceID(certificateDER: Data("local-device".utf8))
    static let peerDevice = SyncDeviceID(certificateDER: Data("peer-device".utf8))

    static let epoch = Date(timeIntervalSince1970: 900_000)

    static func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    static func item(_ text: String, concealed: Bool = false, at date: Date) -> ClipItem {
        ClipItem(
            kind: .text,
            text: text,
            payload: ClipPayload(representations: [PasteboardType.string: Data(text.utf8)]),
            createdAt: date,
            isConcealed: concealed
        )
    }

    /// The content identity a peer would compute for the same text.
    ///
    /// `ClipKind.text` has no `identityTypes`, so the hash covers the kind and the
    /// text and ignores the payload — which is what lets a peer name this content
    /// without holding the same bytes.
    static func contentHash(_ text: String) -> String {
        ClipItem.hash(
            kind: .text,
            text: text,
            payload: ClipPayload(representations: [:]),
            fileURLs: []
        )
    }

    /// One item as a peer would describe it.
    static func meta(
        _ text: String,
        pinned: Bool = false,
        concealed: Bool = false,
        at date: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> SyncClipMeta {
        SyncClipMeta(
            contentHash: contentHash(text),
            kind: ClipKind.text.rawValue,
            preview: text,
            createdAt: date,
            isPinned: LWWRegister(value: pinned, timestamp: date, deviceID: peerDevice),
            isConcealed: concealed,
            originDeviceID: peerDevice,
            representations: [plainTextDescriptor(byteCount: text.utf8.count)]
        )
    }

    static let plainTextKey = RepresentationKey(
        canonical: "text/plain;charset=utf-8",
        origin: PasteboardType.string
    )

    static func plainTextDescriptor(byteCount: Int) -> RepresentationDescriptor {
        RepresentationDescriptor(key: plainTextKey, byteCount: byteCount)
    }

    /// A second representation, so a test can offer one item whose bytes arrive
    /// in more than one instalment — which is what `SyncExchange` does whenever
    /// its per-round budget runs out mid-item.
    static let richTextKey = RepresentationKey(
        canonical: "text/rtf",
        origin: PasteboardType.rtf
    )

    /// One item claiming both representations, so a caller can hand over one set
    /// of bytes now and the other later.
    static func twoRepresentationMeta(_ text: String) -> SyncClipMeta {
        let base = meta(text)
        return SyncClipMeta(
            contentHash: base.contentHash,
            kind: base.kind,
            preview: base.preview,
            createdAt: base.createdAt,
            isPinned: base.isPinned,
            isConcealed: base.isConcealed,
            originDeviceID: base.originDeviceID,
            representations: [
                plainTextDescriptor(byteCount: text.utf8.count),
                RepresentationDescriptor(key: richTextKey, byteCount: text.utf8.count),
            ]
        )
    }

    static func peer(named name: String) -> PairedPeer {
        PairedPeer(
            certificateDER: Data("certificate-of-\(name)".utf8),
            deviceName: name,
            platform: .linux,
            pairedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
