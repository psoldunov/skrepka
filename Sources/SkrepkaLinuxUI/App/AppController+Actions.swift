import CGtk4
import Foundation
import SkrepkaIPC

// The tray's menu actions and the daemon's answers, split from the controller
// by kind: that file joins the pieces, this one is what they ask for.
extension AppController {
    func perform(_ action: AppMenu.Action) {
        switch action {
        case .problem:
            // The only thing the app can do about a daemon that is not
            // running is try again — and Settings says what went wrong.
            ensureDaemon()
            openSettings()
        case .openPicker:
            showPicker()
        case .clearHistory:
            confirmClearHistory()
        case .settings:
            openSettings()
        case .quit:
            quit()
        }
    }

    // MARK: - The daemon

    /// Starts the daemon if it is not running. The first call to the bus
    /// activates it when the activation file is installed; the starter covers
    /// the installs where it is not.
    func ensureDaemon() {
        let session = session
        let inbox = inbox
        Task(priority: .medium) {
            let outcome = await DaemonStarter.ensureRunning(on: session)
            inbox?.post(.daemon(outcome))
        }
    }

    func handle(_ event: AppEvent) {
        switch event {
        case .daemon(let outcome):
            note(outcome)
        case .cleared(.success(let answer)) where !answer.ok:
            AppAlert.show(message: "History was not cleared", detail: answer.detail)
        case .cleared(.failure(let failure)):
            AppAlert.show(message: "History was not cleared", detail: failure.message)
        case .cleared(.success):
            break
        }
    }

    private func note(_ outcome: DaemonStarter.Outcome) {
        switch outcome {
        case .running, .started:
            setDaemonProblem(nil)
        case .failed(let reason):
            FileHandle.standardError.write(Data("skrepka-gui: \(reason)\n".utf8))
            setDaemonProblem("Skrepka's background service isn't running")
        }
    }

    private func setDaemonProblem(_ headline: String?) {
        guard headline != daemonProblem else { return }
        daemonProblem = headline
        tray?.update(menu: AppMenu.menu(problem: headline))
        tray?.setProblem(headline)
    }

    // MARK: - Clear History

    /// The macOS wording, and the macOS rule: pinned entries stay.
    private func confirmClearHistory() {
        picker?.hide()
        ConfirmDialog.ask(
            over: nil,
            message: "Clear clipboard history?",
            detail: "Pinned entries are kept. This cannot be undone.",
            confirm: "Clear"
        ) { [weak self] in
            self?.clearHistory()
        }
    }

    private func clearHistory() {
        let session = session
        let inbox = inbox
        Task(priority: .medium) {
            do {
                let answer = try await SkrepkaBus.proxy(on: session).clear(keepingPinned: true)
                inbox?.post(.cleared(.success(answer)))
            } catch {
                inbox?.post(.cleared(.failure(ClearFailure(message: String(describing: error)))))
            }
        }
    }
}
