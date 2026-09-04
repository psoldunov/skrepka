import AppKit
import SwiftUI

/// Owns the first-run window.
///
/// Separate from ``SettingsWindowController`` because this one is shown once
/// and thrown away — keeping it alive afterwards would hold a window nothing
/// can ever reopen.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private unowned let coordinator: AppCoordinator
    private let onFinish: () -> Void

    init(coordinator: AppCoordinator, onFinish: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onFinish = onFinish
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        // Same reasoning as the settings window: Clippy is LSUIElement, so
        // nothing yields activation to it and `makeKeyAndOrderFront` alone
        // would order the window only within Clippy's own layer.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func close() {
        window?.close()
        window = nil
        onFinish()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: WelcomeView(coordinator: coordinator) { [weak self] in self?.close() }
        )
        // Unlike the settings window, this one sizes itself to its content.
        // There is only one layout here, so nothing can jump between panes —
        // and a fixed height clipped the footer buttons off the bottom as soon
        // as a line of copy wrapped.
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Clippy"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        return window
    }
}
