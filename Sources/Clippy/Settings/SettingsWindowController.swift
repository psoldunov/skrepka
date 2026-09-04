import AppKit
import SwiftUI

/// Owns the settings window.
///
/// Created lazily and kept afterwards, so reopening restores where the user
/// left it.
@MainActor
final class SettingsWindowController {
    private unowned let coordinator: AppCoordinator
    private var window: NSWindow?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show() {
        let isFirstShow = window == nil
        let window = window ?? makeWindow()
        self.window = window

        if isFirstShow {
            window.center()
        }
        // `activate()` asks for keyboard focus, and that is all it can do:
        // NSApplication.h says it activates "if possible" and "does not
        // guarantee that the app will be activated at all" without the
        // frontmost app first calling `yieldActivationToApplication:`. Clippy
        // is LSUIElement, so nothing ever yields to it — activation is refused,
        // `makeKeyAndOrderFront` orders the window only within Clippy's own
        // layer, and Settings opens behind whatever the user was using.
        //
        // `orderFrontRegardless` is what actually puts it in front, the same
        // way PickerPanelController does. Activation is also asynchronous, so
        // ordering could not depend on it even when it does land.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(coordinator: coordinator))
        // The window is a fixed size, so the hosting controller must not push a
        // preferred size of its own — that is what made it resize, and grow from
        // its bottom-left origin, every time the pane changed.
        hosting.sizingOptions = []

        let window = NSWindow(contentViewController: hosting)
        window.title = "Clippy Settings"
        // Transparent and full-size so the glass cards read against the
        // window's own vibrant backdrop rather than a flat grey panel, and the
        // tab bar can sit where a toolbar would.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsView.windowSize)
        return window
    }
}
