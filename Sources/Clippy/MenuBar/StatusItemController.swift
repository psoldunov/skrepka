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
        let openDiagnostics: () -> Void
        let clearHistory: () -> Void
        let quit: () -> Void
    }

    private let statusItem: NSStatusItem
    /// The warning row, kept out of the menu until there is something to say.
    private var problemItem: NSMenuItem?
    /// Hidden and shown with the row above it. A hidden item "does not appear
    /// in a menu" (`NSMenuItem.h`), but nothing in AppKit elides a separator
    /// stranded beside one — leaving it visible put a stray divider across the
    /// top of the menu on a healthy machine.
    private var problemSeparator: NSMenuItem?
    private var problem: DiagnosticsProblem?
    /// Held by reference rather than looked up by index: the menu's first item
    /// is now the warning row, and an index would silently retarget.
    private var openItem: NSMenuItem?
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

    /// Puts the current problem — or its absence — on the icon and in the menu.
    ///
    /// Both, deliberately: the badge is what the user notices, and the menu row
    /// is what tells them which of the two silent failures they have hit.
    func showProblem(_ problem: DiagnosticsProblem?) {
        guard problem != self.problem else { return }
        self.problem = problem
        statusItem.button?.image = StatusItemIcon.image(badged: problem != nil)
        statusItem.button?.toolTip = problem?.headline ?? "Clippy — clipboard history"

        problemItem?.title = problem?.headline ?? ""
        problemItem?.isHidden = problem == nil
        problemSeparator?.isHidden = problem == nil
    }

    /// The warning row. Built hidden and revealed by ``showProblem(_:)``, so
    /// the menu keeps a stable shape rather than growing an item at the top the
    /// first time something goes wrong.
    private func makeProblemItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "",
            action: #selector(MenuActions.openDiagnostics),
            keyEquivalent: ""
        )
        item.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        item.isHidden = true
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let problemItem = makeProblemItem()
        let problemSeparator = NSMenuItem.separator()
        problemSeparator.isHidden = true
        menu.addItem(problemItem)
        menu.addItem(problemSeparator)
        self.problemItem = problemItem
        self.problemSeparator = problemSeparator

        let open = NSMenuItem(
            title: "Open Clippy",
            action: #selector(MenuActions.showPicker),
            keyEquivalent: ""
        )
        menu.addItem(open)
        openItem = open
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
        openItem?.toolTip = KeyboardShortcuts.getShortcut(for: .showPicker)
            .map { "Shortcut: \(ShortcutFormatter.string(for: $0))" }
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
    @objc func openDiagnostics() { actions.openDiagnostics() }
    @objc func clearHistory() { actions.clearHistory() }
    @objc func quit() { actions.quit() }
}
