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
        // An accessory app has to activate to put a real window in front.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
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
