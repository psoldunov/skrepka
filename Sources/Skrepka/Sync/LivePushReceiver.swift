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
/// **The pause/resume dance is the primary echo suppressor.**
/// `ClipboardWatcher.pause()` stops the watcher acting on a change, and
/// `resume()` re-reads `changeCount` so whatever happened while paused is
/// discarded — the same pair `AppCoordinator.choose(_:style:)` already uses so
/// that pasting an entry is not re-recorded. `SyncCoordinator.recentlyReceived`
/// is the second, for the case where the window is missed.
@MainActor
struct LivePushReceiver {
    /// Why a push was not written. Logged rather than shown: the user did not
    /// ask for this write and has nothing to do about it.
    private enum Refusal: String {
        case pickerOpen = "the picker was open"
        case noUsableRepresentation = "no representation could be put on this pasteboard"
    }

    private let watcher: ClipboardWatcher
    private let pasteService: PasteService
    /// Whether the picker panel is on screen.
    ///
    /// A closure rather than a reference to the panel controller, so this type
    /// stays testable and does not reach into `AppCoordinator`'s private state.
    private let isPickerVisible: @MainActor () -> Bool

    init(
        watcher: ClipboardWatcher,
        pasteService: PasteService = PasteService(),
        isPickerVisible: @escaping @MainActor () -> Bool
    ) {
        self.watcher = watcher
        self.pasteService = pasteService
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
    /// **Only ever called with bytes that came inline**, so an item over
    /// `SyncLimits.livePushInlineLimit` reaches this device's history and never
    /// its clipboard. `.noUsableRepresentation` below is the refusal that
    /// records it. That is a limitation of this phase, not a defence: see
    /// ``SyncCoordinator/receiveLivePush(_:inline:)`` for why fetching the
    /// missing bytes needs a request lock on `SyncInitiator` before it can be
    /// wired, and `docs/linux-sync/phase-3-runbook.md` step 4.
    func write(_ meta: SyncClipMeta, payloads: [RepresentationKey: Data]) async {
        guard !isPickerVisible() else { return refuse(.pickerOpen) }
        let representations = RepresentationKeyMap.utiKeyed(payloads)
        guard !representations.isEmpty else { return refuse(.noUsableRepresentation) }

        // Skrepka is about to own the pasteboard; do not re-record our own write.
        await watcher.pause()
        _ = await pasteService.deliver(
            PasteService.Request(
                // No files: what arrives from a peer is bytes, and the paths the
                // other machine copied from are not paths this one has. A push
                // therefore writes one pasteboard item, which is what it held.
                contents: ClipContents(
                    payload: ClipPayload(representations: representations),
                    fileURLs: []
                ),
                plainText: meta.preview,
                style: .rich,
                // The peer's, so another clipboard manager on this Mac
                // attributes the content to the app it was copied from rather
                // than to Skrepka. Absent for a Linux peer, which has no bundle
                // identifiers.
                sourceBundleID: meta.sourceBundleID,
                target: nil,
                shouldPaste: false
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
