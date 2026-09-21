import AppKit
import Foundation
import SkrepkaCore
import SkrepkaSync
import os

/// Puts content a peer pushed live onto this Mac's pasteboard.
///
/// **Through `PasteService`, never through `NSPasteboard` directly.** There is
/// one place in this app that owns the pasteboard and it already exists; a
/// second write path is how the `org.nspasteboard.source` marker ends up set on
/// one and not the other, and other clipboard managers then attribute the
/// content to Skrepka.
///
/// **Paused around the write, and the pause is enough here.**
/// `ClipboardWatcher.pause()` stops the watcher acting on a change, and
/// `resume()` re-reads `changeCount` so whatever happened while paused is
/// discarded — the same pair `AppCoordinator.choose(_:style:)` already uses so
/// that pasting an entry is not re-recorded. It works on the Mac because the
/// pasteboard write is synchronous: the change has happened by the time
/// `resume()` reads the count. (Linux's writes are queued, which is why the
/// daemon marks them as a handoff instead of pausing.) Behind it,
/// `SyncCoordinator.livePushGate` refuses to push the content back if a
/// capture of it gets through anyway.
///
/// **Kept on this Mac.** The write is marked current-host-only, so Universal
/// Clipboard does not relay it to another Mac — which, running Skrepka, would
/// capture it as its own copy and push it back.
@MainActor
struct LivePushReceiver {
    /// Why a push was not written. Logged rather than shown: the user did not
    /// ask for this write and has nothing to do about it.
    private enum Refusal: String {
        case pickerOpen = "the picker was open"
        case noUsableRepresentation = "no representation could be put on this pasteboard"
        case superseded = "something was copied or pushed since, or sync stopped"
    }

    private let watcher: ClipboardWatcher
    private let pasteService: PasteService
    /// Whether the picker panel is on screen.
    ///
    /// A closure rather than a reference to the panel controller, so this type
    /// stays testable and does not reach into `AppCoordinator`'s private state.
    private let isPickerVisible: @MainActor () -> Bool
    /// Where the files a pushed file copy carries are written before they go
    /// on the pasteboard. Nil pastes such a copy as its files' names.
    private let fileCache: FileCache?

    init(
        watcher: ClipboardWatcher,
        pasteService: PasteService = PasteService(),
        fileCache: FileCache?,
        isPickerVisible: @escaping @MainActor () -> Bool
    ) {
        self.watcher = watcher
        self.pasteService = pasteService
        self.fileCache = fileCache
        self.isPickerVisible = isPickerVisible
    }

    /// Writes one received item, or declines and says why.
    ///
    /// **Never while the picker is open.** The user is looking at a list and
    /// about to choose from it; replacing the clipboard under them is the silent
    /// destructive failure design §11 warns about, and the item is in the list
    /// they are looking at anyway.
    ///
    /// `shouldPaste: false` and `target: nil` deliberately: a live push is a
    /// handoff of the clipboard, not a paste into whatever happens to be
    /// frontmost. Synthesising ⌘V here would type a peer's clipboard into the
    /// user's document.
    ///
    /// Called with the bytes that came inline, or — for an item over
    /// `SyncLimits.livePushInlineLimit` — with the bytes fetched straight
    /// after the push; see ``SyncCoordinator/receiveFetchedPush(_:payloads:)``.
    ///
    /// **A file copy never pastes the sender's path.** Its files are written
    /// here and pasted as local files, or its names are pasted when none came —
    /// see ``ForeignFilePasteboard``.
    ///
    /// **`claim` is asked after that work, immediately before the write.**
    /// Materialising and transcoding take a moment; a copy the user makes
    /// meanwhile, or sync being switched off, must win over a peer's push. A
    /// refused claim writes nothing, and files already materialised stay cached
    /// for a later paste from history. The one suspension left between the
    /// claim and the write is the hop to pause the watcher. Claiming before
    /// that hop rather than after it means a copy landing inside it is still
    /// recorded, where after it the pause would discard it.
    func write(
        _ meta: SyncClipMeta,
        payloads: [RepresentationKey: Data],
        claim: @MainActor () -> Bool
    ) async {
        guard !isPickerVisible() else { return refuse(.pickerOpen) }
        let representations = RepresentationKeyMap.utiKeyed(payloads)
        guard !representations.isEmpty else { return refuse(.noUsableRepresentation) }
        let fileItems = await ForeignFilePasteboard.items(
            for: ForeignFilePasteboard.Row(
                kind: ClipKind(rawValue: meta.kind) ?? .text,
                representations: representations,
                preview: meta.preview,
                contentHash: meta.contentHash,
                // Pushed by a peer, so recorded there: its paths are not ours.
                isForeign: true
            ),
            cache: fileCache
        )
        // Asked again: materialising and transcoding take a moment, and the
        // user may have opened the picker meanwhile.
        guard !isPickerVisible() else { return refuse(.pickerOpen) }
        guard claim() else { return refuse(.superseded) }

        // Skrepka is about to own the pasteboard; do not re-record our own write.
        await watcher.pause()
        _ = await pasteService.deliver(
            PasteService.Request(
                // No file URLs: the paths the other machine copied from are not
                // paths this one has. A file copy's local files, when it brought
                // any, are in `fileItems`.
                contents: ClipContents(
                    payload: ClipPayload(representations: representations),
                    fileURLs: []
                ),
                fileItems: fileItems,
                plainText: meta.preview,
                style: .rich,
                // The peer's, so another clipboard manager on this Mac
                // attributes the content to the app it was copied from rather
                // than to Skrepka. Absent for a Linux peer, which has no bundle
                // identifiers.
                sourceBundleID: meta.sourceBundleID,
                target: nil,
                shouldPaste: false,
                // Universal Clipboard would relay this to the user's other
                // Macs, and one running Skrepka would capture it as its own
                // copy and push it back out — see `PasteService.Request`.
                staysOnThisMac: true
            )
        )
        await watcher.resume()
    }

    private func refuse(_ refusal: Refusal) {
        SkrepkaLog.sync.debug(
            "Did not put a live push on the pasteboard: \(refusal.rawValue, privacy: .public)"
        )
    }
}
