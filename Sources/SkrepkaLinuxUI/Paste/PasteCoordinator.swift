import Foundation
import SkrepkaLinuxPlatform

protocol PasteHandling: AnyObject {
    func paste()
    func setAutomaticPasteEnabled(_ enabled: Bool)
}

extension PasteHandling {
    func setAutomaticPasteEnabled(_: Bool) {}
}

final class PasteCoordinator: PasteHandling {
    private(set) var mechanism: PasteMechanism
    private let probe: () -> PasteMechanism
    private let remoteDesktop: RemoteDesktopPaster
    private let showAlert: (String, String) -> Void
    private var timer: LoopTimer?
    private var didShowFailure = false
    private var isAutomaticPasteEnabled = true

    init(
        mechanism: PasteMechanism = .probe(),
        probe: @escaping () -> PasteMechanism = { .probe() },
        portalConnection: @escaping () -> DBusConnection?,
        showAlert: @escaping (String, String) -> Void = AppAlert.show
    ) {
        self.mechanism = mechanism
        self.probe = probe
        self.showAlert = showAlert
        remoteDesktop = RemoteDesktopPaster(connection: portalConnection)
        AppLog.note("paste: selected \(mechanism.summary)")
    }

    func paste() {
        timer?.cancel()
        timer = LoopTimer(milliseconds: 80) { [weak self] in
            self?.timer = nil
            self?.perform()
        }
    }

    func setAutomaticPasteEnabled(_ enabled: Bool) {
        if enabled, !isAutomaticPasteEnabled { didShowFailure = false }
        isAutomaticPasteEnabled = enabled
        remoteDesktop.setAutomaticPasteEnabled(enabled)
    }

    private func perform() {
        if mechanism == .copyOnly {
            mechanism = probe()
            if mechanism != .copyOnly { AppLog.note("paste: reprobed and selected \(mechanism.summary)") }
        }
        let environment = ProcessInfo.processInfo.environment
        switch mechanism {
        case .xTest:
            attempt { try XTestPaster().paste(displayName: environment["DISPLAY"]) }
        case .virtualKeyboard:
            attempt { try VirtualKeyboardPaster().paste(displayName: environment["WAYLAND_DISPLAY"]) }
        case .remoteDesktopPortal:
            remoteDesktop.paste { [weak self] result in self?.finished(result) }
        case .copyOnly:
            failed(PasteFailure("no supported input-injection mechanism is available"))
        }
    }

    private func attempt(_ operation: () throws -> Void) {
        do {
            try operation()
            AppLog.note("paste: Ctrl+V sent through \(mechanism.summary)")
        } catch {
            failed(error)
        }
    }

    func finished(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            AppLog.note("paste: Ctrl+V sent through \(mechanism.summary)")
        case .failure(let error as PasteFailure) where !error.shouldNotify:
            AppLog.note("paste: copied only: \(error)")
        case .failure(let error):
            failed(error)
        }
    }

    private func failed(_ error: any Error) {
        AppLog.note("paste: \(mechanism.summary) failed: \(error)")
        guard !didShowFailure else { return }
        didShowFailure = true
        showAlert(
            "Skrepka copied the entry but could not paste it",
            (error as? PasteFailure)?.userDetail
                ?? "Press Ctrl+V manually. Allow Skrepka if your desktop asks for keyboard-control permission."
        )
    }
}
