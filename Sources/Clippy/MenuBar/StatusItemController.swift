import AppKit
import ClippyCore
import KeyboardShortcuts
import os

/// The menu bar icon and its menu.
///
/// `NSStatusItem` rather than SwiftUI's `MenuBarExtra`: SwiftUI exposes no
/// handle on the status button and no way to open its window programmatically,
/// and Clippy needs both — the hotkey has to drive the same surface a click does.
@MainActor
final class StatusItemController {
    /// What the menu can ask the coordinator to do.
    struct Actions {
        let showPicker: () -> Void
        let openSettings: () -> Void
        let clearHistory: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    /// Objective-C target for the menu items. Held here because `NSMenuItem`
    /// keeps only a weak reference to its target.
    private let menuTarget: MenuActions

    init(actions: Actions) {
        menuTarget = MenuActions(actions: actions)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        statusItem.menu = makeMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            ClippyLog.panel.error("Status item has no button; the menu bar icon will be missing.")
            return
        }
        button.image = StatusItemIcon.image()
        button.toolTip = "Clippy — clipboard history"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: "Open Clippy",
            action: #selector(MenuActions.showPicker),
            keyEquivalent: ""
        )
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Clear History…",
                action: #selector(MenuActions.clearHistory),
                keyEquivalent: ""
            )
        )
        menu.addItem(
            NSMenuItem(
                title: "Settings…",
                action: #selector(MenuActions.openSettings),
                keyEquivalent: ","
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Clippy", action: #selector(MenuActions.quit), keyEquivalent: "q")
        )

        for item in menu.items {
            item.target = menuTarget
        }
        return menu
    }

    /// Shows the user's shortcut as a trailing hint on the menu item.
    ///
    /// A real `keyEquivalent` is deliberately not set: the shortcut is already
    /// registered globally through Carbon, and a matching menu equivalent fires
    /// a second time whenever the panel is key.
    func refreshShortcut() {
        guard let item = statusItem.menu?.items.first else { return }
        item.toolTip = KeyboardShortcuts.getShortcut(for: .showPicker)
            .map { "Shortcut: \($0.description)" }
    }
}

/// Objective-C selector target for the menu. `NSMenuItem` needs one; keeping it
/// separate is what lets `StatusItemController` stay a plain Swift type.
@MainActor
private final class MenuActions: NSObject {
    private let actions: StatusItemController.Actions

    init(actions: StatusItemController.Actions) {
        self.actions = actions
    }

    @objc func showPicker() { actions.showPicker() }
    @objc func openSettings() { actions.openSettings() }
    @objc func clearHistory() { actions.clearHistory() }
    @objc func quit() { actions.quit() }
}
