import CGtk4

/// A yes-or-no question over the Settings window, for the one action that is
/// hard to take back: forgetting a paired device.
///
/// GTK's `GtkAlertDialog`, which draws the platform's own dialog. The choice
/// comes back through a GIO async callback, and the closure to run rides in its
/// user data, retained once and released by that callback — which GTK calls
/// exactly once per `choose`.
enum ConfirmDialog {
    /// Calls `confirmed` only if the person chose `confirm`. Escape, the close
    /// button and Cancel all mean no, and Return lands on Cancel.
    static func ask(
        over parent: UnsafeMutablePointer<GtkWindow>,
        message: String,
        detail: String,
        confirm: String,
        confirmed: @escaping () -> Void
    ) {
        guard let dialog = skrepka_alert_dialog_new(message) else { return }
        gtk_alert_dialog_set_detail(dialog, detail)
        skrepka_alert_dialog_set_buttons(dialog, "Cancel", confirm)
        gtk_alert_dialog_set_cancel_button(dialog, 0)
        gtk_alert_dialog_set_default_button(dialog, 0)
        gtk_alert_dialog_choose(
            dialog,
            parent,
            nil,
            onChosen,
            Unmanaged.passRetained(Choice(confirmed)).toOpaque()
        )
        // The running choice holds its own reference to the dialog.
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }

    /// The closure to run on a yes.
    private final class Choice {
        let confirmed: () -> Void

        init(_ confirmed: @escaping () -> Void) {
            self.confirmed = confirmed
        }
    }

    private static let onChosen: GAsyncReadyCallback = { source, result, data in
        guard let data else { return }
        let choice = Unmanaged<Choice>.fromOpaque(data).takeRetainedValue()
        // The error is not read: a dismissed dialog answers the cancel button's
        // index, and there is nothing else an alert can fail with that would
        // change what to do — which is nothing.
        let index = gtk_alert_dialog_choose_finish(OpaquePointer(source), result, nil)
        if index == 1 {
            choice.confirmed()
        }
    }
}
