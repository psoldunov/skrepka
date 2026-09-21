import Foundation
import SkrepkaSync
import Testing

@testable import SkrepkaCore

/// A representation a row was learned without, whose bytes arrive later — the
/// bundle a sender withheld under its file-size limit and offers once the limit
/// is raised. Dropped, it would be fetched again every round.
extension HistoryStoringTests {
    @Test(
        "A representation first offered after the row was learned is kept when its bytes arrive",
        arguments: HistoryStoreEngine.all)
    func lateRepresentationIsKept(engine: HistoryStoreEngine) async throws {
        let store = try await Self.makeStore(engine)
        let path = RepresentationKey(canonical: "text/uri-list", origin: "public.file-url")
        let pathBytes = Data("file:///Users/someone/shot.png".utf8)
        let bundle = try FileBundle(files: [FileBundle.File(name: "shot.png", bytes: Data("x".utf8))])
            .encoded()
        let hash = String(repeating: "d", count: 64)
        let pathOnly = RepresentationDescriptor(key: path, byteCount: pathBytes.count)
        try await store.capture(Self.lateMeta(hash, offering: [pathOnly]), payloads: [path: pathBytes])

        let withBundle = Self.lateMeta(
            hash,
            offering: [pathOnly, RepresentationDescriptor(key: FileBundle.key, byteCount: bundle.count)])
        try await store.capture(withBundle, payloads: [FileBundle.key: bundle])

        #expect(try await store.payload(for: hash, key: FileBundle.key) == bundle)
        #expect(try await store.payload(for: hash, key: path) == pathBytes)
    }

    private static func lateMeta(
        _ hash: String,
        offering representations: [RepresentationDescriptor]
    ) -> SyncClipMeta {
        let date = EngineFixtures.at(5)
        return SyncClipMeta(
            contentHash: hash,
            kind: ClipKind.file.rawValue,
            preview: "shot.png",
            createdAt: date,
            isPinned: LWWRegister(value: false, timestamp: date, deviceID: EngineFixtures.peerDevice),
            originDeviceID: EngineFixtures.peerDevice,
            representations: representations
        )
    }
}
