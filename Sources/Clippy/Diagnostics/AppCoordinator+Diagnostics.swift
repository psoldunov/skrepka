import ClippyCore

/// The coordinator's health duties: what it reports about itself, and the
/// first-run window that exists to get the one permission it cannot work
/// without.
///
/// Split from ``AppCoordinator`` because these answers are a job of their own —
/// they read the system rather than drive the app — and because the coordinator
/// is the one file every feature touches.
extension AppCoordinator {
    // MARK: - Diagnostics

    /// Everything the Status pane and the pasted report need.
    ///
    /// Gathered whole, and only where the whole thing is wanted: the menu bar
    /// badge uses ``refreshHealth()`` instead.
    var diagnosticsSnapshot: DiagnosticsSnapshot {
        gatherer.snapshot(
            health: captureHealth,
            preferences: preferences,
            storage: storage,
            itemCount: store.items.count
        )
    }

    /// The system's current policy for programmatic pasteboard reads.
    ///
    /// The one clipboard answer a view cannot observe — it is changed in System
    /// Settings. Everything else about capture lives in ``captureHealth``,
    /// which is `@Observable` and read directly by the views that show it.
    var clipboardAccessPolicy: PasteboardAccess {
        gatherer.accessPolicy
    }

    /// Pushes the current problem, if any, at the menu bar.
    ///
    /// Gathers only what the ranking needs. This runs on every clipboard
    /// change, and a full snapshot would cost an `SMAppService` round trip the
    /// badge has no use for.
    func refreshHealth() {
        statusItem?.showProblem(
            gatherer.problem(health: captureHealth, preferences: preferences, storage: storage)
        )
    }

    /// Provokes the system's pasteboard access alert, and records the answer.
    ///
    /// Capture is paused for the round trip: the probe writes a marker to the
    /// general pasteboard, and an unpaused poller would file that marker as the
    /// user's very first history entry. `resume()` re-baselines the change
    /// counter, so the write is skipped rather than captured late.
    ///
    /// - Returns: true when the marker read back intact — the only proof
    ///   available after an "Allow Once", which leaves the policy at `.ask`.
    func probeClipboardAccess() async -> Bool {
        await poller.pause()
        let granted = gatherer.probeAccess()
        await poller.resume()
        if granted { captureHealth.recordSuccessfulProbe() }
        refreshHealth()
        return granted
    }

    // MARK: - First run

    /// Shows the welcome window once, ever.
    ///
    /// The flag is written before the window appears, not after it is
    /// dismissed: a crash while it is on screen should not mean the user meets
    /// it again on every launch.
    func showWelcomeIfNeeded() {
        guard !preferences.hasCompletedFirstRun else { return }
        preferences.hasCompletedFirstRun = true
        let controller = WelcomeWindowController(coordinator: self) { [weak self] in
            self?.welcomeWindow = nil
            self?.refreshHealth()
        }
        welcomeWindow = controller
        controller.show()
    }
}
