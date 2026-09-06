import AppKit

/// An ordinary-looking window for an app that can never become active.
///
/// Skrepka is `LSUIElement`, and `NSApplication.activate()` is best-effort:
/// `NSApplication.h` says the framework "does not guarantee that the app will
/// be activated at all" unless the frontmost app first calls
/// `yieldActivationToApplication:`. Nothing ever yields to an accessory app, so
/// Skrepka does not get activation on request. A plain `NSWindow` therefore
/// opens *unfocused* — the window server routes key events to the active app,
/// so the title bar draws inactive, the keyboard goes elsewhere, and the next
/// window anyone raises buries it.
///
/// `.nonactivatingPanel` is the way out, and the one ``PickerPanel`` already
/// takes: the window server lets such a panel hold key status while its
/// application is inactive.
///
/// Unlike ``PickerPanel`` this one stays at the normal window level. A settings
/// window that floated over every other app would be worse than one that opens
/// behind: ``showFocused()`` puts it in front when it is opened, and after that
/// it yields to whatever the user raises next, the way a window should.
final class AccessoryPanel: NSPanel {
    /// Already true for every mask this class is built with. A non-activating
    /// panel refuses key status only when it has no title bar, which is
    /// ``PickerPanel``'s case rather than this one — measured against the macOS
    /// 26 SDK, where `[.titled, .closable, .fullSizeContentView,
    /// .nonactivatingPanel]` answers true and `[.nonactivatingPanel,
    /// .fullSizeContentView]` answers false. Overridden anyway because
    /// `styleMask` is a caller-supplied parameter: a caller that drops
    /// `.titled` would otherwise get a panel that cannot take the keyboard.
    override var canBecomeKey: Bool { true }
    /// Main status belongs to the active application, which Skrepka is not.
    /// `NSPanel` already answers false; stated so the guarantee outlives any
    /// change to the mask.
    override var canBecomeMain: Bool { false }

    /// Builds the panel around a title bar Skrepka draws its own content into.
    ///
    /// The style mask is passed to the designated initializer rather than
    /// assigned afterwards: `.nonactivatingPanel` is read when the window is
    /// created, and a panel built without it never accepts key status while the
    /// app is inactive, whatever the mask says later.
    init(contentViewController: NSViewController, styleMask: NSWindow.StyleMask) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentViewController.view.frame.size),
            styleMask: styleMask.union(.nonactivatingPanel),
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController

        // The one line here that changes a default rather than pinning one: a
        // panel hides itself when its application deactivates, and Skrepka
        // deactivates constantly — every click into another app would take the
        // window with it.
        hidesOnDeactivate = false
        // Already false on `NSPanel`. Pinned because the panel has to be key
        // the moment it opens, not only once something inside it wants the
        // keyboard.
        becomesKeyOnlyIfNeeded = false
        // Already false on `NSPanel`. Pinned because both controllers cache
        // their window and reuse it after a close, and a released one would
        // leave them holding a dead reference.
        isReleasedWhenClosed = false
        // The menu bar stays reachable in full screen, so Settings can be asked
        // for while a full-screen app owns the active space. Without this the
        // panel cannot be shown there and is parked on the desktop instead,
        // where nothing appears to have happened — and nothing activates
        // Skrepka to switch spaces on the user's behalf.
        //
        // Deliberately narrower than ``PickerPanel``'s set: `.canJoinAllSpaces`
        // and `.stationary` are right for a picker that must open wherever the
        // user already is, and wrong for a window they should be able to leave
        // on one space. The cost of leaving them out is that reopening the
        // cached panel from a different space raises it on the space it was
        // opened on.
        collectionBehavior = [.fullScreenAuxiliary]
    }

    /// Brings the panel to the front and gives it the keyboard.
    ///
    /// `orderFrontRegardless` rather than `makeKeyAndOrderFront`, for the same
    /// reason ``PickerPanelController`` uses it: only `orderFrontRegardless`
    /// orders a window ahead of other applications' windows while its own app
    /// is inactive. `makeKey` afterwards, because ordering does not confer key
    /// status.
    func showFocused() {
        orderFrontRegardless()
        makeKey()
    }
}
