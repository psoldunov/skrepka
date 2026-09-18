import CGtk4
import Foundation
import SkrepkaIPC

/// Joins the Sync pane, the pairing dialog and the daemon link.
///
/// It holds the one ``SyncModel`` and does three things with it: sends what
/// the widgets ask for through ``DaemonLink`` — marking it in flight first —
/// applies what the link reports, and redraws. Every decision is the model's;
/// this only moves values between the pieces.
///
/// Lives on GTK's main-loop thread. The link's reports reach it through a
/// ``MainLoopWatch``, so nothing here is ever called from another thread, and
/// all it sends the other way is a ``SyncAction`` value, queued synchronously,
/// and the shutdown, from a `Task` that captures only the link.
final class SyncController {
    /// Called once the link has shut down, after ``close()``.
    var onShutDown: (() -> Void)?

    private let pane: SyncPane
    private let dialog: PairingDialog
    private let parent: UnsafeMutablePointer<GtkWindow>
    private let link: DaemonLink
    private var model = SyncModel()
    private var watch: MainLoopWatch<SyncEvent>?
    private var ticker: LoopTimer?
    /// What was last drawn, so an unchanged model redraws nothing.
    private var drawnPane: SyncPaneState?
    private var drawnPrompt: PairingPromptText?
    /// Set once the window has closed and its widgets are gone. Reports still
    /// arrive until the link has shut down; none of them may reach a widget.
    private var isClosed = false

    init(
        pane: SyncPane,
        dialog: PairingDialog,
        parent: UnsafeMutablePointer<GtkWindow>,
        link: DaemonLink,
        inbox: MainLoopInbox<SyncEvent>
    ) throws {
        self.pane = pane
        self.dialog = dialog
        self.parent = parent
        self.link = link
        self.watch = try MainLoopWatch(inbox: inbox) { [weak self] event in
            self?.handle(event)
        }
        // Once a second, for what runs out by itself: the countdown under a
        // code, a code nobody confirmed, a success notice that has been up
        // long enough, "synced a minute ago".
        self.ticker = LoopTimer(seconds: 1) { [weak self] in
            self?.tick()
        }
        wire()
        render()
    }

    private func wire() {
        pane.onPairingSwitch = { [weak self] isOn in
            self?.send(isOn ? .openPairingWindow : .closePairingWindow)
        }
        pane.onPair = { [weak self] deviceID in self?.send(.pair(deviceID: deviceID)) }
        pane.onUnpair = { [weak self] deviceID in self?.confirmUnpair(deviceID) }
        pane.onLivePush = { [weak self] deviceID, isOn in
            self?.send(.setLivePush(deviceID: deviceID, isOn: isOn))
        }
        pane.onSyncNow = { [weak self] in self?.send(.syncNow) }
        pane.onDismissBanner = { [weak self] in
            guard let self else { return }
            self.update(self.model.dismissingNotice())
        }
        dialog.onConfirm = { [weak self] in
            guard let self, let prompt = self.model.prompt else { return }
            self.send(.answer(deviceID: prompt.deviceID, accept: true))
        }
        dialog.onCancel = { [weak self] in
            guard let self else { return }
            self.apply(self.model.cancellingPrompt(now: Date()))
        }
    }

    // MARK: - Out

    private func send(_ action: SyncAction) {
        guard !isClosed else { return }
        update(model.sending(action))
        // Queued here, synchronously, rather than from a `Task`: the link
        // works through its queue in the order this thread filled it.
        link.perform(action)
    }

    private func confirmUnpair(_ deviceID: String) {
        let name = model.peers?.peers.first { $0.deviceID == deviceID }?.name ?? "this device"
        ConfirmDialog.ask(
            over: parent,
            message: "Forget \(name)?",
            detail: """
                Skrepka will stop trusting this device and will forget its certificate. \
                Nothing already synced is deleted.
                """,
            confirm: "Unpair"
        ) { [weak self] in
            self?.send(.unpair(deviceID: deviceID))
        }
    }

    /// The window is closing. Stops drawing and sending at once, and tells the
    /// link to wind up; ``onShutDown`` fires when it has.
    ///
    /// Nothing is answered from here. The pairing dialog goes down with this
    /// window without a close request of its own, and a code on screen, a peer
    /// waiting behind it and one that dials in while the link winds up all
    /// still need a no — or the other machine waits out its timeout. The link
    /// has seen every one of them and every answer, so it refuses whatever is
    /// left on its way out; see ``DaemonLink/shutdown()``.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        ticker?.cancel()
        let link = link
        Task { await link.shutdown() }
    }

    // MARK: - In

    private func handle(_ event: SyncEvent) {
        if case .shutDown = event {
            watch?.cancel()
            onShutDown?()
            return
        }
        apply(model.applying(event, now: Date()))
    }

    private func apply(_ transition: SyncTransition) {
        update(transition.model)
        for effect in transition.effects {
            send(effect)
        }
    }

    private func tick() {
        update(model.expiring(now: Date()))
    }

    private func update(_ next: SyncModel) {
        model = next
        render()
    }

    private func render() {
        guard !isClosed else { return }
        let now = Date()
        let paneState = SyncPaneState(model, now: now, timeZone: .current)
        if paneState != drawnPane {
            pane.render(paneState)
            drawnPane = paneState
        }
        let promptText = model.prompt.map { PairingPromptText($0, now: now) }
        if promptText != drawnPrompt {
            dialog.render(promptText)
            drawnPrompt = promptText
        }
    }
}
