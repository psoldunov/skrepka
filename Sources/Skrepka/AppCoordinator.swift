import AppKit
import Foundation
import Observation
import SkrepkaCore
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
    /// Where history actually landed, for the diagnostics pane. In-memory when
    /// the on-disk store could not be opened.
    let storage: DiagnosticsSnapshot.Storage
    /// What the capture loop has been doing. Drives the menu bar badge and the
    /// diagnostics pane.
    let captureHealth = CaptureHealth()

    // Internal rather than private: `AppCoordinator+Diagnostics.swift` is the
    // other half of this type, and Swift scopes `private` to the file.
    let gatherer = DiagnosticsGatherer()
    let watcher: ClipboardWatcher
    /// Everything sync owns: identity, the two listeners, discovery, one link
    /// per paired peer. Built here so there stays exactly one place to look for
    /// what owns what; it does nothing until the user switches sync on.
    let sync: SyncCoordinator
    var statusItem: StatusItemController?
    var welcomeWindow: WelcomeWindowController?

    private let pasteService = PasteService()
    private let pickerModel: PickerModel
    private let panelController: PickerPanelController
    /// Built in `start()` rather than `init`, because it needs a fully formed
    /// coordinator to hand to the settings view.
    private var settingsWindow: SettingsWindowController?
    private var captureTask: Task<Void, Never>?
    /// The app that was frontmost when the picker opened, captured before the
    /// panel appears so paste-back knows where to send the keystroke.
    private var pasteTarget: NSRunningApplication?
    /// Skrepka asks for Accessibility at most once per launch, at the moment the
    /// user actually needs it — not on a cold first run, when the request has
    /// no context.
    private var hasRequestedAccessibility = false
    /// Guards against stacking alerts if several pastes fail in a row.
    private var isPresentingNotice = false

    init() {
        let preferences = Preferences()
        self.preferences = preferences

        let opened = Self.openStore(retention: preferences.retentionPolicy)
        store = opened.store
        startupError = opened.startupError
        storage = opened.storage

        watcher = ClipboardWatcher(
            source: PasteboardReader(),
            rules: preferences.captureRules,
            sourceProvider: {
                // NSWorkspace carries no main-actor annotation in the macOS 26
                // SDK, so reading it from the watcher actor is sanctioned.
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
        )
        pickerModel = PickerModel(store: store, captureHealth: captureHealth)
        let panelController = PickerPanelController(model: pickerModel)
        self.panelController = panelController
        sync = SyncCoordinator(
            preferences: preferences,
            store: store,
            livePushReceiver: LivePushReceiver(
                watcher: watcher,
                // Read through a closure rather than handed the controller: the
                // receiver's one rule about the picker is "not while it is
                // open", and that needs a boolean rather than a panel.
                isPickerVisible: { panelController.isVisible }
            )
        )
    }

    /// Opens the on-disk history, or says why it could not.
    ///
    /// Lifted out of `init` because it is the one part of construction with a
    /// decision in it, and because a failure here is a thing the user is told
    /// about rather than a crash.
    ///
    /// An in-memory store keeps the app usable rather than dead on launch. If
    /// even that fails, SwiftData itself is unusable and failing loudly beats
    /// limping on with a broken object graph.
    private static func openStore(
        retention: RetentionPolicy
    ) -> (store: HistoryStore, storage: DiagnosticsSnapshot.Storage, startupError: String?) {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.soldunov.skrepka"
        do {
            let url = try HistoryStore.defaultStoreURL(bundleID: bundleID)
            return (
                try HistoryStore(location: url, retention: retention),
                .onDisk(path: url.path(percentEncoded: false)),
                nil
            )
        } catch {
            SkrepkaLog.store.error("Falling back to in-memory history: \(error.localizedDescription)")
            guard let fallback = try? HistoryStore(location: nil) else {
                fatalError("SwiftData could not create an in-memory store; Skrepka cannot run.")
            }
            return (
                fallback,
                .inMemory(reason: error.localizedDescription),
                """
                Skrepka could not open its history database, so this session will not be saved. \
                \(error.localizedDescription)
                """
            )
        }
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
                openDiagnostics: { [weak self] in self?.openSettings(tab: .diagnostics) },
                clearHistory: { [weak self] in self?.confirmClearHistory() },
                quit: { NSApp.terminate(nil) }
            )
        )

        HotKeyService.register { [weak self] in
            self?.togglePicker()
        }

        startCaptureLoop()
        refreshHealth()
        showWelcomeIfNeeded()
        Task { [sync] in await sync.start() }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        Task { [sync, watcher] in
            await watcher.stop()
            await sync.stop()
        }
    }

    /// Re-reads preferences after the user changes them in Settings.
    func preferencesChanged() {
        store.retention = preferences.retentionPolicy
        let rules = preferences.captureRules
        Task { await watcher.updateRules(rules) }
        statusItem?.refreshShortcut()
    }

    // MARK: - Capture

    private func startCaptureLoop() {
        captureTask = Task { [weak self, watcher, store] in
            let stream = await watcher.start()
            for await decision in stream {
                self?.captureHealth.record(decision)
                self?.refreshHealth()
                guard let item = decision.item else {
                    Self.logRejection(decision)
                    continue
                }
                await store.capture(item)
                // The same stream, not a second watcher: one `changeCount`, one
                // source of truth about what was copied. Live push is offered
                // after the store has it, so a peer never learns about a
                // clipping this machine failed to keep.
                self?.sync.offerLivePush(item)
            }
        }
    }

    private static func logRejection(_ decision: CaptureDecision) {
        guard let message = decision.rejectionLogMessage else { return }
        if decision.isNoteworthyRejection {
            SkrepkaLog.clipboard.notice("\(message, privacy: .public)")
        } else {
            SkrepkaLog.clipboard.debug("\(message, privacy: .public)")
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
    /// Skrepka itself has to be rejected: Settings, the clear-history alert and
    /// the paste-failed notice all call `NSApp.activate()`, so the hotkey can
    /// easily be pressed while Skrepka is frontmost. Pasting into Skrepka would
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
        // The system prompt already offers to open Settings, so Skrepka's own
        // notice would just stack a second dialog on top of it.
        let didPrompt = shouldPaste && requestAccessibilityIfNeeded()
        Task { [pasteService, watcher] in
            // Skrepka is about to own the pasteboard; do not re-record our own write.
            await watcher.pause()
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
            await watcher.resume()

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

    /// Tells the user why the entry was copied rather than pasted.
    private func presentNotice(_ message: String) {
        guard !isPresentingNotice else { return }
        isPresentingNotice = true
        defer { isPresentingNotice = false }

        if UserAlert.confirmOpeningAccessibilitySettings(reason: message) {
            AccessibilityPermission.openSettings()
        }
    }

    // MARK: - Menu actions

    func openSettings(tab: SettingsTab = .general) {
        settingsWindow?.show(tab: tab)
    }

    private func confirmClearHistory() {
        guard UserAlert.confirmClearingHistory() else { return }
        store.clear(keepingPinned: true)
    }
}
