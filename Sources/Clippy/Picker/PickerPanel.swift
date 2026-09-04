import AppKit

/// The floating picker window.
///
/// The combination below is what satisfies three requirements at once: it
/// floats above every app including full-screen ones, it never takes frontmost
/// away from whatever the user was typing in, and it still accepts key events
/// so the search field works.
///
/// `canBecomeKey` must be overridden — a `.nonactivatingPanel` refuses key
/// status by default — and `becomesKeyOnlyIfNeeded` must be false, or the
/// search field never takes first responder.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Main status would make Clippy the active app, which is the one thing
    /// this panel must never do.
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // No `.titled`: a title bar makes `contentLayoutRect` 32 points
            // shorter than the frame, so a panel sized to its content clips the
            // last row. `canBecomeKey` is overridden below, so the panel still
            // takes key without one.
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Without this an `.accessory` app deactivating would yank the panel.
        hidesOnDeactivate = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    /// Escape closes the panel. AppKit routes it here when nothing else claims it.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
