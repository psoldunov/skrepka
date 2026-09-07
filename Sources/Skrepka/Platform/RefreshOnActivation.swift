import AppKit
import Combine
import SwiftUI

extension View {
    /// Runs `refresh` now, and again every time one of Skrepka's surfaces comes
    /// forward.
    ///
    /// The shape every permission surface needs, and the reason it is one
    /// modifier rather than four copies. Permissions and login items are
    /// granted in System Settings, so coming forward is the only moment one of
    /// these answers can have changed; and both the settings and welcome
    /// windows are cached and reused, so `onAppear` alone never fires a second
    /// time. Either half on its own is a stale tick on screen.
    ///
    /// Becoming key is listened for as well as becoming active, because
    /// activation alone does not cover these windows. ``AccessoryPanel`` is
    /// built expressly not to activate the app — `.nonactivatingPanel`,
    /// `canBecomeMain` false, and `showFocused()` deliberately choosing
    /// `orderFrontRegardless()` — so clicking back onto Settings after a trip to
    /// System Settings raises and keys the panel without Skrepka ever becoming
    /// active. Key is the signal these panels actually produce, and without it
    /// the surface that sent the user to System Settings is the one that never
    /// hears they came back.
    ///
    /// The key trigger is reasoned from `.nonactivatingPanel` semantics rather
    /// than measured — settling it wants a window server, a second app and a
    /// real click. The hand-test: toggle Skrepka in System Settings → Login
    /// Items, then click straight back onto the panel without going via the
    /// menu bar. It is safe to ship unmeasured because it only adds refresh
    /// opportunities and removes none, and it is what lets a caller hold a
    /// `@State` snapshot instead of polling inside `body` without the snapshot
    /// being the staler of the two.
    ///
    /// The key notification is filtered to ``AccessoryPanel``, and that filter
    /// is load-bearing rather than tidiness. `NSWindow.didBecomeKeyNotification`
    /// is posted for every window in the process, and ``PickerPanel`` takes key
    /// on every press of the global hotkey — so an unfiltered subscription puts
    /// this refresh on the one path in Skrepka that has to feel instant. What
    /// makes that unacceptable is the *shape* of `SMAppService.mainApp.status`
    /// rather than any one timing: a stack sample shows it is a blocking,
    /// synchronous XPC round-trip to `smd`, made here on the main actor. In a
    /// signed bundle it measures in low single-digit milliseconds warm and a
    /// couple of dozen on a process's first call — small, and still not
    /// something to spend on every hotkey press. (Measure it in a real bundle if
    /// you revisit this: an unbundled probe has no main app to look up and
    /// reports times that describe nothing the app does.)
    ///
    /// The filter is by class, not by window, so any ``AccessoryPanel`` taking
    /// key refreshes every mounted surface — the settings subtree stays mounted
    /// for the life of the process, because `SettingsWindowController` caches
    /// its window and never nils it. Harmless, since the only other such panel
    /// is the first-run welcome window, but do not read the filter as
    /// window-scoped.
    ///
    /// Every surface using this modifier is hosted in an ``AccessoryPanel``, so
    /// the filter loses nothing: those windows coming forward is exactly the
    /// event worth listening for.
    func refreshOnActivation(_ refresh: @escaping () -> Void) -> some View {
        let didActivate = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .map { _ in () }
        let panelDidBecomeKey = NotificationCenter.default
            .publisher(for: NSWindow.didBecomeKeyNotification)
            .filter { $0.object is AccessoryPanel }
            .map { _ in () }

        return onAppear(perform: refresh)
            .onReceive(didActivate.merge(with: panelDidBecomeKey)) { _ in
                refresh()
            }
    }
}
