import Foundation
import SkrepkaCore
import SkrepkaSync
import Testing

@testable import SkrepkaDaemon

/// What a link row puts on this machine's clipboard.
///
/// The field report this pins: an iPhone link relayed to a Mac by Universal
/// Clipboard synced to Linux with no bytes, and the picker answered "nothing
/// in that entry can be written to a Linux clipboard".
@Suite("A link row pastes as its URL")
struct LinkWriteTests {
    static let url =
        "https://www.inherence.dev/admin/intent/edit/id=a2f359826b8646c2bfe117236028a5f5;type=resource"
    /// The identity the Mac gave that row: its kind and its text, hashed.
    static let hash = "4053b993622769695e2e10baedb7349e36fce4737f0673517cffb3fbbff4d060"

    static func row(representations: [String: Data] = [:], preview: String = url) -> WritableRow {
        WritableRow(
            kind: .link,
            representations: representations,
            fileURLs: [],
            preview: preview,
            contentHash: hash,
            isForeign: true
        )
    }

    @Test("a link that arrived with no bytes pastes its URL as text")
    func bareLinkPastesItsURL() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()

        let write = await daemon.clipboardWrite(for: Self.row())

        #expect(write.targets == ["text/plain;charset=utf-8": Data(Self.url.utf8)])
        #expect(write.plainTargets == write.targets)
    }

    @Test("a link whose preview was cut short is still refused")
    func cappedPreviewIsRefused() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()

        let write = await daemon.clipboardWrite(for: Self.row(preview: String(Self.url.prefix(40))))

        #expect(write.targets.isEmpty)
    }

    @Test("a link is not captured back, because what Linux writes for it is plain text")
    func linkWriteReplacesTheRow() async throws {
        // Captured back, the echo would be a `.text` row beside the link: no
        // Linux target carries a `public.url`, and a link hashes its kind.
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let carried = [PasteboardType.string: Data(Self.url.utf8)]

        #expect(await daemon.clipboardWrite(for: Self.row()).replacesRow)
        #expect(await daemon.clipboardWrite(for: Self.row(representations: carried)).replacesRow)
    }

    @Test("a pushed link with no bytes is handed over as its URL")
    func pushedBareLinkIsHandedOver() async throws {
        let (daemon, _) = try ForeignFileWriteTests.daemon()
        let device = try #require(SyncDeviceID(hex: String(repeating: "c", count: SyncDeviceID.hexLength)))
        let stamp = Date()
        let meta = SyncClipMeta(
            contentHash: Self.hash,
            kind: ClipKind.link.rawValue,
            preview: Self.url,
            createdAt: stamp,
            isPinned: LWWRegister(value: false, timestamp: stamp, deviceID: device),
            originDeviceID: device,
            representations: []
        )
        let generation = await daemon.syncGeneration
        await daemon.awaitBytes(meta.contentHash)

        let targets = await daemon.handoffTargets(
            meta, payloads: [:], generation: generation, requiringClipboard: false)

        #expect(targets == ["text/plain;charset=utf-8": Data(Self.url.utf8)])
    }
}
