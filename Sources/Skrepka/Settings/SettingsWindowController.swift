import AppKit
import SwiftUI

/// Owns the settings window.
///
/// Created lazily and kept afterwards, so reopening restores where the user
/// left it.
@MainActor
final class SettingsWindowController {
    private unowned let coordinator: AppCoordinator
    private var window: AccessoryPanel?
    /// Which pane is showing. Held here rather than in the view because the
    /// window is built once and reused, so a `@State` inside `SettingsView`
    /// would survive every later `show(tab:)` and ignore it.
    private let selection = SettingsSelection()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func show(tab: SettingsTab = .general) {
        selection.tab = tab
        let isFirstShow = window == nil
        let window = window ?? makeWindow()
        self.window = window

        if isFirstShow {
            window.center()
        }
        window.showFocused()
    }

    /// A non-activating panel rather than an `NSWindow` — see ``AccessoryPanel``
    /// for why an accessory app cannot focus an ordinary one.
    private func makeWindow() -> AccessoryPanel {
        @Bindable var selection = selection
        let hosting = NSHostingController(
            rootView: SettingsView(coordinator: coordinator, selection: $selection.tab)
        )
        // The window is a fixed size, so the hosting controller must not push a
        // preferred size of its own — that is what made it resize, and grow from
        // its bottom-left origin, every time the pane changed.
        hosting.sizingOptions = []

        // No `.miniaturizable`: an `NSPanel` does not miniaturise, so the flag
        // would only put a dead yellow button in the title bar.
        let window = AccessoryPanel(
            contentViewController: hosting,
            // Transparent and full-size so the glass cards read against the
            // window's own vibrant backdrop rather than a flat grey panel, and
            // the tab bar can be laid out against the top of the window rather
            // than against the bottom of the title bar.
            styleMask: [.titled, .closable, .fullSizeContentView]
        )
        window.title = "Skrepka Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.setContentSize(SettingsView.windowSize)
        return window
    }
}

/// The selected pane, as an object the window controller owns and the view
/// binds to.
@MainActor
@Observable
final class SettingsSelection {
    var tab: SettingsTab = .general
}
