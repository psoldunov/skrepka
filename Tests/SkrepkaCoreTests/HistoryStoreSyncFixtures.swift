// Exercises the SwiftData store, so it is fenced off Linux like the store is.
// Phase 3's HistoryStoringTests runs the same assertions against every conformance.
#if canImport(SwiftData)

    import Foundation
    import SkrepkaSync
    import Testing

    @testable import SkrepkaCore

    /// Shared setup for the store's sync and pairing suites.
    ///
    /// Device identifiers are derived from throwaway bytes rather than written as
    /// literal hex: `SyncDeviceID.init(hex:)` is failable and refuses anything that
    /// is not 64 lowercase hex characters, so deriving them is both shorter and
    /// impossible to get subtly wrong.
    enum SyncFixtures {
        static let localDevice = SyncDeviceID(certificateDER: Data("local-device".utf8))
        static let peerDevice = SyncDeviceID(certificateDER: Data("peer-device".utf8))

        @MainActor
        static func makeStore(
            deviceID: SyncDeviceID? = SyncFixtures.localDevice,
            retention: RetentionPolicy = .unlimited
        ) throws -> HistoryStore {
            let store = try HistoryStore(location: nil, retention: retention)
            store.localDeviceID = deviceID
            return store
        }

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
        /// `ClipKind.text` has no `identityTypes`, so the hash covers the kind and
        /// the text and ignores the payload — which is what lets a peer name this
        /// content without holding the same bytes.
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

        static func plainTextDescriptor(byteCount: Int) -> RepresentationDescriptor {
            RepresentationDescriptor(
                key: RepresentationKey(
                    canonical: "text/plain;charset=utf-8",
                    origin: PasteboardType.string
                ),
                byteCount: byteCount
            )
        }
    }

#endif
