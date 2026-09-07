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
/// Like ``PickerPanel``, this one floats. Sitting at the normal level and
/// yielding to whatever the user raised next was tried first, on the grounds
/// that it is how a window ought to behave — and it is wrong for a window this
/// app owns. Nothing activates Skrepka, so a normal-level panel is buried by
/// the first click into another app, and an accessory app offers no Dock icon
/// and no ⌘-Tab entry to dig it back out. Settings could at least be re-asked
/// for from the menu bar. The welcome window has no reopen path at all, and the
/// teardown that clears first-run state runs only when it closes, so burying it
/// strands the user on the first run with no way back.
///
/// The level is set once and never moved. A panel is on screen only between
/// ``showFocused()`` and `close()`, so floating "until dismissed" is what a
/// constant level already means; nothing here needs to juggle levels to
/// simulate one.
///
/// Floating costs one thing, and it is paid for in ``AppModalWindow``: an
/// `NSAlert` or `NSOpenPanel` is born at `.normal`, so a modal opened from a
/// panel that floats above it would swallow every event while drawing behind
/// the window that opened it.
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

        // Pinned, not changed: a plain `NSPanel` hides itself when its
        // application deactivates, and Skrepka deactivates constantly — every
        // click into another app would take the window with it. The
        // `.nonactivatingPanel` unioned in above already forces this false,
        // measured on the macOS 26 SDK: the same mask answers false with that
        // bit and true without it. Stated anyway so the guarantee does not rest
        // on one bit of a caller-supplied mask.
        hidesOnDeactivate = false
        // Already false on `NSPanel`. Pinned because the panel has to be key
        // the moment it opens, not only once something inside it wants the
        // keyboard.
        becomesKeyOnlyIfNeeded = false
        // Already false on `NSPanel`. Pinned because both controllers cache
        // their window and reuse it after a close, and a released one would
        // leave them holding a dead reference.
        isReleasedWhenClosed = false
        // Floats until dismissed — see the class comment for why an accessory
        // app cannot afford a normal-level window. Both lines are needed
        // because the relationship runs one way only, measured on the macOS 26
        // SDK rather than assumed: assigning `isFloatingPanel` sets `level` to
        // `.floating`, while assigning `level` leaves the flag reading false.
        // Level alone would stack the panel correctly and still have it answer
        // `isFloatingPanel == false` to anything that asks, which is why
        // ``PickerPanel`` sets both too.
        level = .floating
        isFloatingPanel = true
        // `.fullScreenAuxiliary` keeps the menu bar's Settings item honest while
        // a full-screen app owns the active space. Without it the panel cannot
        // be shown there and is parked on the desktop instead, where nothing
        // appears to have happened — and nothing activates Skrepka to switch
        // spaces on the user's behalf.
        //
        // `.managed` because the level above is no longer `.normal`, and
        // `NSWindow.h` hangs this group's default on the level: `.managed`
        // ("Participates in spaces, exposé") is the default only at
        // `NSNormalWindowLevel`, and everything above it defaults to
        // `.transient` — "Floats in spaces, hidden by exposé". A window that
        // floats *and* cannot be found in Mission Control is harder to recover
        // than the buried one this change replaces, so the group is stated
        // rather than inherited.
        //
        // The Primary/Auxiliary/CanJoinAllApplications group is left
        // unspecified, so it keeps inheriting from `.fullScreenAuxiliary`:
        // `NSWindow.h` gives an unspecified group "the default treatment
        // determined by its other collection behaviors". Two of its members
        // have a claim on these windows — `.auxiliary` is "About or Settings
        // windows, as well as utility panes", and `.canJoinAllApplications`
        // is for "floating windows and system overlays", which "join other
        // apps' sets and full screen spaces when eligible". Naming either one
        // displaces the inherited default. Choosing between them needs a
        // hand-test — open Settings while another app owns a full-screen space
        // — and nobody has run it.
        //
        // Reopening a cached panel from a different space still raises it on
        // the space it was opened on. That is unresolved rather than handled.
        // `.moveToActiveSpace` looks like the fix and was tried, but it is
        // documented against the window *becoming active* — which a
        // `.nonactivatingPanel` with `canBecomeMain == false`, in an app that
        // never gets activation, cannot do. It was removed rather than shipped
        // on a claim that could not be demonstrated.
        collectionBehavior = [.managed, .fullScreenAuxiliary]
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
