import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// A push whose bytes came after it — a picture over the inline limit, a file
/// copy — reaches the clipboard once, only if nothing newer happened here, and
/// never after sync was turned off.
@Suite("Bytes fetched after a push are handed over at most once")
struct FetchOnPushTests {
    static let png = ForeignFileWriteTests.png

    static func meta(
        kind: ClipKind = .image,
        hash: String = String(repeating: "e", count: 64)
    ) throws -> SyncClipMeta {
        let device = try #require(SyncDeviceID(hex: String(repeating: "c", count: SyncDeviceID.hexLength)))
        let stamp = Date()
        return SyncClipMeta(
            contentHash: hash,
            kind: kind.rawValue,
            preview: "picture",
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: []
        )
    }

    static let picture = [RepresentationKey(canonical: "image/png", origin: "public.png"): png]

    static func targets(_ daemon: Daemon, _ meta: SyncClipMeta, generation: Int) async -> [String: Data]? {
        await daemon.handoffTargets(
            meta, payloads: Self.picture, generation: generation, requiringClipboard: false)
    }

    @Test("fetched bytes of the push being waited on are written once")
    func writtenOnce() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let meta = try Self.meta()
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(meta.contentHash)

        #expect(await Self.targets(daemon, meta, generation: generation)?["image/png"] == Self.png)
        #expect(await Self.targets(daemon, meta, generation: generation) == nil)
    }

    @Test("bytes nobody is waiting on are not written")
    func unrequestedBytesAreNotWritten() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let generation = await daemon.syncGeneration
        #expect(await Self.targets(daemon, try Self.meta(), generation: generation) == nil)
    }

    @Test("a copy made here while the bytes were in flight wins")
    func newerLocalCopyWins() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let meta = try Self.meta()
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(meta.contentHash)

        await daemon.noteLocalCopy(String(repeating: "f", count: 64))

        #expect(await Self.targets(daemon, meta, generation: generation) == nil)
    }

    @Test("a newer push supersedes the one still waiting")
    func newerPushWins() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let older = try Self.meta()
        let newer = try Self.meta(hash: String(repeating: "b", count: 64))
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(older.contentHash)
        await daemon.awaitBytes(newer.contentHash)

        #expect(await Self.targets(daemon, older, generation: generation) == nil)
        #expect(await Self.targets(daemon, newer, generation: generation) != nil)
    }

    @Test("bytes landing after sync went off are not written")
    func notAfterSyncOff() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let meta = try Self.meta()
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(meta.contentHash)

        await daemon.stopSyncStack(closingSystemBus: false)

        #expect(await Self.targets(daemon, meta, generation: generation) == nil)
        await daemon.receiveFetchedPush(meta, payloads: Self.picture, generation: generation)
    }

    @Test("a pushed file copy is handed over as local files, not the sender's path")
    func pushedFileIsMaterialised() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let meta = try Self.meta(kind: .file)
        let bundle = FileBundle(files: [FileBundle.File(name: "shot.png", bytes: Self.png)])
        let payloads: [RepresentationKey: Data] = [
            FileBundle.key: try bundle.encoded(),
            RepresentationKey(canonical: "text/uri-list", origin: "public.file-url"):
                Data("file:///Users/philipp/shot.png".utf8),
        ]
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(meta.contentHash)

        let targets = try #require(
            await daemon.handoffTargets(
                meta, payloads: payloads, generation: generation, requiringClipboard: false))

        let gnome = ForeignFileWriteTests.text(targets["x-special/gnome-copied-files"])
        #expect(gnome.hasPrefix("copy\nfile://"))
        #expect(targets.values.allSatisfy { !ForeignFileWriteTests.text($0).contains("/Users/") })
        #expect(targets["image/png"] == Self.png)
    }
}

extension Daemon {
    /// What `fetchPushed(_:from:generation:)` records before it asks a link.
    func awaitBytes(_ contentHash: String) {
        livePushGate.noteAwaitingBytes(contentHash)
    }

    /// What recording a copy made on this machine tells the gate.
    func noteLocalCopy(_ contentHash: String) {
        _ = livePushGate.admitCopy(contentHash, isConcealed: false, at: Date())
    }
}
