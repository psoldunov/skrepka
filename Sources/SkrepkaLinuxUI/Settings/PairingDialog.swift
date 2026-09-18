import CGtk4

/// The code both screens show, and the question the person answers about it.
///
/// A window of its own rather than a `GtkAlertDialog`, because it changes while
/// it is up: connecting, then the code with its countdown, then the answer on
/// its way, then — if it did not pair — why. ``render(_:)`` with nil hides it;
/// it is built once and reused, like the palette, so a second pairing is not a
/// second set of widgets.
///
/// Every way of closing it — Cancel, Close, Escape, the title bar — is
/// ``onCancel``. The controller decides what that means, and a code on screen
/// is answered no rather than dropped.
final class PairingDialog {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    private let window: UnsafeMutablePointer<GtkWindow>
    private let windowWidget: GtkWidgetPointer
    private let heading: GtkWidgetPointer
    private let device: GtkWidgetPointer
    private let code: GtkWidgetPointer
    private let status: GtkWidgetPointer
    private let spinner: GtkWidgetPointer
    private let cancel: GtkWidgetPointer
    private let confirm: GtkWidgetPointer
    private var isShowing = false

    init(parent: UnsafeMutablePointer<GtkWindow>) throws {
        guard let windowWidget = gtk_window_new(),
            let window = skrepka_as_window(windowWidget),
            let content = GtkBuild.box(vertical: true, spacing: 14),
            let heading = GtkBuild.label(
                "", classes: [SettingsStyle.dialogTitle], wraps: true, centred: true),
            let device = GtkBuild.label("", classes: [SettingsStyle.secondary], centred: true),
            let code = GtkBuild.label("", classes: [SettingsStyle.code], centred: true),
            let spinner = gtk_spinner_new(),
            let status = GtkBuild.label("", wraps: true, centred: true),
            let cancel = GtkBuild.button("Cancel"),
            let confirm = GtkBuild.button(PairingPromptText.confirm, classes: ["suggested-action"])
        else { throw SettingsError.widgetCreationFailed }

        Self.configure(window, parent: parent)
        // Copyable so the code can go into a message to whoever is at the
        // other machine.
        GtkBuild.makeCopyable(code)
        GtkBuild.makeCopyable(device)
        let statusRow = try Self.row([spinner, status], spacing: 8, align: GTK_ALIGN_CENTER)
        let buttons = try Self.row([cancel, confirm], spacing: 10, align: GTK_ALIGN_END)
        GtkBuild.margins(content, vertical: 24, horizontal: 24)
        for child in [heading, device, code, statusRow, buttons] {
            GtkBuild.append(child, to: content)
        }
        gtk_window_set_child(window, content)

        self.window = window
        self.windowWidget = windowWidget
        self.heading = heading
        self.device = device
        self.code = code
        self.status = status
        self.spinner = spinner
        self.cancel = cancel
        self.confirm = confirm
        connect()
    }

    private static func row(
        _ children: [GtkWidgetPointer],
        spacing: Int32,
        align: GtkAlign
    ) throws -> GtkWidgetPointer {
        guard let box = GtkBuild.box(vertical: false, spacing: spacing) else {
            throw SettingsError.widgetCreationFailed
        }
        gtk_widget_set_halign(box, align)
        for child in children {
            GtkBuild.append(child, to: box)
        }
        return box
    }

    /// Modal over the Settings window, a fixed size, closed with it.
    private static func configure(
        _ window: UnsafeMutablePointer<GtkWindow>, parent: UnsafeMutablePointer<GtkWindow>
    ) {
        gtk_window_set_transient_for(window, parent)
        gtk_window_set_modal(window, 1)
        gtk_window_set_destroy_with_parent(window, 1)
        gtk_window_set_resizable(window, 0)
        gtk_window_set_default_size(window, 420, -1)
        skrepka_close_on_escape(window)
    }

    private func connect() {
        GtkSignal.connect(UnsafeMutableRawPointer(cancel), "clicked") { [weak self] in self?.onCancel?() }
        GtkSignal.connect(UnsafeMutableRawPointer(confirm), "clicked") { [weak self] in self?.onConfirm?() }
        // Kept open: whether it may close is the controller's call, and it
        // says so by rendering nil.
        GtkSignal.onCloseRequest(UnsafeMutableRawPointer(window)) { [weak self] in
            self?.onCancel?()
            return true
        }
    }

    func render(_ text: PairingPromptText?) {
        guard let text else {
            if isShowing { GtkBuild.setVisible(windowWidget, false) }
            isShowing = false
            return
        }
        gtk_window_set_title(window, text.title)
        GtkBuild.setText(heading, text.title)
        GtkBuild.setText(device, text.device)
        GtkBuild.setText(code, text.code ?? "")
        GtkBuild.setVisible(code, text.code != nil)
        GtkBuild.setText(status, text.status)
        GtkBuild.setVisible(spinner, text.isWorking)
        gtk_spinner_set_spinning(skrepka_as_spinner(spinner), text.isWorking ? 1 : 0)
        gtk_button_set_label(skrepka_as_button(cancel), text.cancelLabel)
        GtkBuild.setVisible(confirm, text.confirmLabel != nil)
        GtkBuild.setEnabled(confirm, text.isConfirmEnabled)
        guard !isShowing else { return }
        isShowing = true
        // Nothing pre-selected: Return on a freshly shown code must not pair.
        // Set before presenting, so it is the focus the window maps with.
        gtk_window_set_focus(window, cancel)
        gtk_window_present(window)
    }
}
