import AppKit
import ClippyCore
import Foundation
import Observation
import SwiftUI
import os

/// Wires the pieces together: store, capture loop, hotkey, menu bar, picker.
///
/// Everything long-lived hangs off this one object, so there is exactly one
/// place to look for "what owns what".
@MainActor
@Observable
final class AppCoordinator {
    let preferences: Preferences
    let store: HistoryStore
    /// Non-nil when construction failed; surfaced in Settings rather than
    /// swallowed, because a store that failed to open means no history at all.
    private(set) var startupError: String?

    private let poller: PasteboardPoller
    private let pasteService = PasteService()
    private let pickerModel: PickerModel
    private let panelController: PickerPanelController
    private var statusItem: StatusItemController?
    /// Built in `start()` rather than `init`, because it needs a fully formed
    /// coordinator to hand to the settings view.
    private var settingsWindow: SettingsWindowController?
    private var captureTask: Task<Void, Never>?
    /// The app that was frontmost when the picker opened, captured before the
    /// panel appears so paste-back knows where to send the keystroke.
    private var pasteTarget: NSRunningApplication?
    /// Clippy asks for Accessibility at most once per launch, at the moment the
    /// user actually needs it — not on a cold first run, when the request has
    /// no context.
    private var hasRequestedAccessibility = false
    /// Guards against stacking alerts if several pastes fail in a row.
    private var isPresentingNotice = false

    init() {
        let preferences = Preferences()
        self.preferences = preferences

        let bundleID = Bundle.main.bundleIdentifier ?? "com.psoldunov.clippy"
        var startupError: String?
        let store: HistoryStore
        do {
            let url = try HistoryStore.defaultStoreURL(bundleID: bundleID)
            store = try HistoryStore(location: url, retention: preferences.retentionPolicy)
        } catch {
            ClippyLog.store.error("Falling back to in-memory history: \(error.localizedDescription)")
            startupError =
                "Clippy could not open its history database, so this session will not be saved. \(error.localizedDescription)"
            // An in-memory store keeps the app usable rather than dead on launch.
            // If even that fails SwiftData itself is unusable, and failing loudly
            // beats limping on with a broken object graph.
            guard let fallback = try? HistoryStore(location: nil) else {
                fatalError("SwiftData could not create an in-memory store; Clippy cannot run.")
            }
            store = fallback
        }
        self.store = store
        self.startupError = startupError

        poller = PasteboardPoller(
            rules: preferences.captureRules,
            sourceProvider: {
                // NSWorkspace carries no main-actor annotation in the macOS 26
                // SDK, so reading it from the poller actor is sanctioned.
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        )
        pickerModel = PickerModel(store: store)
        panelController = PickerPanelController(model: pickerModel)
    }

    // MARK: - Lifecycle

    func start() {
        settingsWindow = SettingsWindowController(coordinator: self)
        pickerModel.onChoose = { [weak self] item, style in
            self?.choose(item, style: style)
        }
        pickerModel.onDismiss = { [weak self] in
            self?.panelController.dismiss()
        }

        statusItem = StatusItemController(
            actions: .init(
                showPicker: { [weak self] in self?.togglePicker() },
                openSettings: { [weak self] in self?.openSettings() },
                clearHistory: { [weak self] in self?.confirmClearHistory() },
                quit: { NSApp.terminate(nil) }
            )
        )

        HotKeyService.register { [weak self] in
            self?.togglePicker()
        }

        startCaptureLoop()
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        Task { await poller.stop() }
    }

    /// Re-reads preferences after the user changes them in Settings.
    func preferencesChanged() {
        store.retention = preferences.retentionPolicy
        let rules = preferences.captureRules
        Task { await poller.updateRules(rules) }
        statusItem?.refreshShortcut()
    }

    // MARK: - Capture

    private func startCaptureLoop() {
        captureTask = Task { [poller, store] in
            let stream = await poller.start()
            for await decision in stream {
                guard let item = decision.item else {
                    Self.logRejection(decision)
                    continue
                }
                store.capture(item)
            }
        }
    }

    private static func logRejection(_ decision: CaptureDecision) {
        switch decision {
        case .captured:
            break
        case .rejectedPrivacyMarker:
            ClippyLog.clipboard.debug("Skipped an entry marked transient or concealed.")
        case .rejectedExcludedApp(let bundleID):
            ClippyLog.clipboard.debug("Skipped an entry from excluded app \(bundleID, privacy: .public).")
        case .rejectedEmpty:
            ClippyLog.clipboard.debug("Skipped an empty pasteboard change.")
        case .rejectedTooLarge(let byteCount):
            ClippyLog.clipboard.notice("Skipped an entry of \(byteCount) bytes — over the size limit.")
        }
    }

    // MARK: - Picker

    private func togglePicker() {
        if panelController.isVisible {
            panelController.dismiss()
            return
        }
        // Captured before the panel appears. The panel is non-activating so this
        // stays correct, but reading it up front removes the ordering question.
        pasteTarget = Self.pasteTarget(frontmost: NSWorkspace.shared.frontmostApplication)
        panelController.show()
    }

    /// The app a paste should go to, or nil when there is nobody sensible.
    ///
    /// Clippy itself has to be rejected: Settings, the clear-history alert and
    /// the paste-failed notice all call `NSApp.activate()`, so the hotkey can
    /// easily be pressed while Clippy is frontmost. Pasting into Clippy would
    /// activate it, send ⌘V nowhere, and report success — the user loses their
    /// original app *and* the paste. Nil instead makes `PasteService` say so.
    private static func pasteTarget(frontmost: NSRunningApplication?) -> NSRunningApplication? {
        guard frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return frontmost
    }

    private func choose(_ item: ClipSummary, style: PasteStyle) {
        panelController.dismiss()

        guard let payload = store.payload(for: item.id) else {
            presentNotice("That entry could not be loaded.")
            return
        }

        let target = pasteTarget
        let shouldPaste = preferences.pasteAutomatically
        // The system prompt already offers to open Settings, so Clippy's own
        // notice would just stack a second dialog on top of it.
        let didPrompt = shouldPaste && requestAccessibilityIfNeeded()
        Task { [pasteService, poller] in
            // Clippy is about to own the pasteboard; do not re-record our own write.
            await poller.pause()
            let outcome = await pasteService.deliver(
                PasteService.Request(
                    payload: payload,
                    plainText: item.text,
                    style: style,
                    sourceBundleID: item.sourceBundleID,
                    target: target,
                    shouldPaste: shouldPaste
                )
            )
            await poller.resume()

            if case .copiedOnly(let reason) = outcome, let reason, !didPrompt {
                presentNotice(reason)
            }
        }
    }

    // MARK: - Permissions

    /// Shows the system Accessibility prompt the first time a paste needs it.
    ///
    /// - Returns: true when the prompt was shown just now.
    private func requestAccessibilityIfNeeded() -> Bool {
        guard !AccessibilityPermission.isTrusted, !hasRequestedAccessibility else { return false }
        hasRequestedAccessibility = true
        AccessibilityPermission.requestIfNeeded()
        return true
    }

    /// Tells the user why the entry was copied rather than pasted, and offers
    /// the one action that fixes it.
    private func presentNotice(_ message: String) {
        guard !isPresentingNotice else { return }
        isPresentingNotice = true
        defer { isPresentingNotice = false }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Copied, but not pasted"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityPermission.openSettings()
        }
    }

    // MARK: - Menu actions

    private func openSettings() {
        settingsWindow?.show()
    }

    private func confirmClearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned entries are kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear(keepingPinned: true)
    }
}
