import AppKit
import SwiftUI

/// Owns the first-run window.
///
/// Separate from ``SettingsWindowController`` because this one is shown once
/// and thrown away — keeping it alive afterwards would hold a window nothing
/// can ever reopen.
///
/// An `NSObject` so it can be the window's delegate: every way out of this
/// window has to run the same teardown, and `windowWillClose(_:)` is the only
/// place that sees all of them.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: AccessoryPanel?
    private unowned let coordinator: AppCoordinator
    private let onFinish: () -> Void

    init(coordinator: AppCoordinator, onFinish: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onFinish = onFinish
        super.init()
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.showFocused()
    }

    /// Asks the window to go away. The teardown is
    /// ``windowWillClose(_:)``'s, not this method's — see there for why.
    private func dismiss() {
        window?.close()
    }

    private func makeWindow() -> AccessoryPanel {
        let hosting = NSHostingController(
            rootView: WelcomeView(coordinator: coordinator) { [weak self] in self?.dismiss() }
        )
        // Unlike the settings window, this one sizes itself to its content.
        // There is only one layout here, so nothing can jump between panes —
        // and a fixed height clipped the footer buttons off the bottom as soon
        // as a line of copy wrapped.
        hosting.sizingOptions = [.preferredContentSize]

        let window = AccessoryPanel(
            contentViewController: hosting,
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.title = "Welcome to Skrepka"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.delegate = self
        // Sized here, before `show()` places it. `.preferredContentSize` only
        // reaches the window after SwiftUI's first layout pass, which lands
        // *after* `center()` — so the window was centred at whatever size it
        // happened to have and then grew from its fixed corner, which is what
        // left the first-run window sitting off to one side of the screen.
        window.setContentSize(hosting.sizeThatFits(in: contentProposal))
        return window
    }

    /// The space offered to ``WelcomeView`` when measuring it: its own fixed
    /// width, and as much height as the screen can show. Proposing an infinite
    /// height instead invites a greedy layout to claim it.
    private var contentProposal: CGSize {
        CGSize(
            width: WelcomeView.windowWidth,
            height: NSScreen.main?.visibleFrame.height ?? Self.assumedScreenHeight
        )
    }

    /// Stands in for the screen when `NSScreen.main` reports none — taller than
    /// this window has any need to be, so nothing is compressed, and finite so
    /// a greedy layout cannot claim it. Only reachable with no display
    /// attached, where nothing is drawn anyway.
    private static let assumedScreenHeight: CGFloat = 900

    // MARK: - NSWindowDelegate

    /// The one teardown path.
    ///
    /// Done, the close button and Escape all arrive here — an `NSPanel` closes
    /// on `cancelOperation:` where an `NSWindow` does not, so the button stopped
    /// being the only way out the moment this window became a panel. Doing the
    /// work in the delegate rather than in the Done handler is what stops
    /// `onFinish` being skipped, and it is why `dismiss()` only closes.
    func windowWillClose(_ notification: Notification) {
        window = nil
        // `onFinish` clears the coordinator's reference to this controller,
        // which is the only strong one — so `self` can be released part way
        // through the call. Held across it rather than reasoned about.
        withExtendedLifetime(self) { onFinish() }
    }
}
