import CGtk4
import Foundation
import SkrepkaIPC

/// Joins the General, History, Privacy and Diagnostics panes and the Sync
/// pane's sharing switch to the daemon, the autostart entry and the shortcut.
///
/// ``SyncController``'s counterpart: it holds the one ``PreferencesModel``,
/// sends what the widgets ask for as ``DaemonLink`` jobs, applies what comes
/// back, and redraws. Every decision is the model's or a pane state's.
///
/// Lives on GTK's main-loop thread. Jobs report through a ``MainLoopWatch``.
final class PreferencesController {
    struct Panes {
        let general: GeneralPane
        let history: HistoryPane
        let privacy: PrivacyPane
        let sync: SyncPane
        let diagnostics: DiagnosticsPane
    }

    private let panes: Panes
    private let parent: UnsafeMutablePointer<GtkWindow>
    private let link: DaemonLink
    private let connect: PreferencesJobs.Connect
    private let inbox: MainLoopInbox<PreferencesEvent>
    private let autostartEntry: AutostartEntry
    private var model = PreferencesModel()
    private var shortcut: GlobalShortcutsState
    private var autostart: AutostartStatus
    private var watch: MainLoopWatch<PreferencesEvent>?
    private var ticker: LoopTimer?
    private var isClosed = false

    init(panes: Panes, parent: UnsafeMutablePointer<GtkWindow>, services: SettingsWindow.Services) throws {
        self.panes = panes
        self.parent = parent
        self.link = services.link
        self.connect = services.connect
        self.inbox = try MainLoopInbox()
        self.autostartEntry = services.autostart
        self.autostart = services.autostart.status
        self.shortcut = services.shortcut
        self.watch = try MainLoopWatch(inbox: inbox) { [weak self] event in
            self?.handle(event)
        }
        // For a success notice whose time is up.
        self.ticker = LoopTimer(seconds: 1) { [weak self] in
            guard let self else { return }
            self.update(self.model.expiring(now: Date()))
        }
        wire()
        render()
        load()
    }

    private func wire() {
        panes.general.onLaunchAtLogin = { [weak self] isOn in self?.setLaunchAtLogin(isOn) }
        panes.history.onKeepAtMost = { [weak self] items in self?.send(SettingsPatch(maximumItems: items)) }
        panes.history.onDiscardAfter = { [weak self] days in self?.send(SettingsPatch(maximumAgeDays: days)) }
        panes.history.onClear = { [weak self] in self?.confirmClear() }
        panes.history.onDismissBanner = { [weak self] in self?.dismissNotice() }
        panes.privacy.onDismissBanner = { [weak self] in self?.dismissNotice() }
        panes.sync.onSharing = { [weak self] isOn in self?.send(SettingsPatch(syncEnabled: isOn)) }
        panes.diagnostics.onRefresh = { [weak self] in self?.diagnose() }
        panes.diagnostics.onCopy = { [weak self] text in
            guard let self else { return }
            skrepka_copy_text(skrepka_window_as_widget(self.parent), text)
        }
    }

    // MARK: - Out

    /// Reads the settings again — when the window opens, and when a pane
    /// that shows them comes forward.
    func load() {
        run { connect in await PreferencesJobs.load(connect) }
    }

    func diagnose() {
        run { connect in await PreferencesJobs.diagnose(connect) }
    }

    /// The shortcut as the app's portal session last reported it.
    func setShortcut(_ state: GlobalShortcutsState) {
        shortcut = state
        render()
    }

    private func send(_ patch: SettingsPatch) {
        guard !isClosed, model.isEditable else { return }
        update(model.sending(patch))
        run { connect in await PreferencesJobs.change(patch, connect) }
    }

    private func confirmClear() {
        ConfirmDialog.askToClear(over: parent) { [weak self] keepingPinned in
            guard let self, !self.isClosed else { return }
            self.update(self.model.clearing())
            self.run { connect in await PreferencesJobs.clear(keepingPinned: keepingPinned, connect) }
        }
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        autostart = autostartEntry.setEnabled(isOn)
        render()
    }

    private func dismissNotice() {
        update(model.dismissingNotice())
    }

    /// Queues `job` on the link, posting what it finds to this window.
    private func run(_ job: @escaping @Sendable (PreferencesJobs.Connect) async -> PreferencesEvent) {
        guard !isClosed else { return }
        let connect = connect
        let inbox = inbox
        link.run { inbox.post(await job(connect)) }
    }

    /// The window is closing: nothing more is drawn or sent. Jobs already
    /// queued still run; their reports land nowhere.
    func close() {
        isClosed = true
        ticker?.cancel()
        watch?.cancel()
    }

    // MARK: - In

    private func handle(_ event: PreferencesEvent) {
        update(model.applying(event, now: Date()))
    }

    private func update(_ next: PreferencesModel) {
        model = next
        render()
    }

    private func render() {
        guard !isClosed else { return }
        panes.general.render(GeneralPaneState(shortcut: shortcut, autostart: autostart))
        panes.history.render(HistoryPaneState(model))
        panes.privacy.render(PrivacyPaneState(model))
        panes.sync.renderSharing(SharingSwitchState(model))
        panes.diagnostics.render(DiagnosticsPaneState(model.diagnosis, timeZone: .current))
    }
}
