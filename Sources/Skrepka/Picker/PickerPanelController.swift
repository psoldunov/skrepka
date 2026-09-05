import AppKit
import SwiftUI

/// Owns the picker panel's lifecycle: showing it, dismissing it, and the event
/// monitors that close it when the user clicks away.
@MainActor
final class PickerPanelController {
    private let model: PickerModel
    private var panel: PickerPanel?
    /// `addGlobalMonitorForEvents` returns an opaque token typed `Any?`.
    private var outsideClickMonitor: Any?
    private var resignObserver: (any NSObjectProtocol)?

    var isVisible: Bool { panel?.isVisible ?? false }

    init(model: PickerModel) {
        self.model = model
        model.onResultsChange = { [weak self] in self?.syncHeight() }
    }

    func show() {
        model.reset()

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(PickerPlacement.frame(height: model.desiredPanelHeight), display: false)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront`: the latter
        // would activate Skrepka, which is exactly what the non-activating panel
        // exists to avoid.
        panel.orderFrontRegardless()
        panel.makeKey()
        if let contentView = panel.contentViewController?.view {
            panel.makeFirstResponder(contentView)
        }
        model.requestSearchFocus()
        startMonitors()
    }

    func dismiss() {
        stopMonitors()
        panel?.orderOut(nil)
    }

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel(contentRect: PickerPlacement.frame(height: model.desiredPanelHeight))
        // A hosting *controller* with sizing disabled: the controller is what
        // wires SwiftUI into the window's responder chain, so `@FocusState`
        // works and the search field can take the caret. `sizingOptions = []`
        // stops it pinning the view to its fitting size, which would centre the
        // content and leave dead space above and below the list.
        let hosting = NSHostingController(rootView: PickerView(model: model))
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        return panel
    }

    /// Regrows the panel around its fixed top edge when the result count
    /// changes. Driven by the model, not by a SwiftUI layout pass.
    private func syncHeight() {
        guard let panel, panel.isVisible else { return }
        let target = PickerPlacement.resized(panel.frame, toHeight: model.desiredPanelHeight)
        guard abs(target.height - panel.frame.height) > 0.5 else { return }
        panel.setFrame(target, display: true, animate: false)
    }

    // MARK: - Dismissal

    private func startMonitors() {
        stopMonitors()

        // Global monitors are observe-only — they cannot swallow the click, which
        // is what we want: the click should reach whatever the user aimed at.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        guard let panel else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func stopMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }
}
