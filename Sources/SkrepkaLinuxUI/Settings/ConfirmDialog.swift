import CGtk4

/// A question over the Settings window, for the actions that are hard to take
/// back: forgetting a paired device, and clearing history.
///
/// GTK's `GtkAlertDialog`, which draws the platform's own dialog. The choice
/// comes back through a GIO async callback, and the closure to run rides in its
/// user data, retained once and released by that callback — which GTK calls
/// exactly once per `choose`.
enum ConfirmDialog {
    /// Calls `confirmed` only if the person chose `confirm`. Escape, the close
    /// button and Cancel all mean no, and Return lands on Cancel.
    static func ask(
        over parent: UnsafeMutablePointer<GtkWindow>?,
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
            Unmanaged.passRetained(Choice { if $0 == 1 { confirmed() } }).toOpaque()
        )
        // The running choice holds its own reference to the dialog.
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }

    /// The History pane's Clear…: the Mac's three answers. Calls `chosen`
    /// with whether to keep pinned entries, and not at all for Cancel —
    /// which Escape, the close button and Return all mean.
    static func askToClear(
        over parent: UnsafeMutablePointer<GtkWindow>?,
        chosen: @escaping (_ keepingPinned: Bool) -> Void
    ) {
        guard let dialog = skrepka_alert_dialog_new("Clear clipboard history?") else { return }
        gtk_alert_dialog_set_detail(dialog, "This cannot be undone.")
        skrepka_alert_dialog_set_three_buttons(dialog, "Cancel", "Clear, keeping pinned", "Clear everything")
        gtk_alert_dialog_set_cancel_button(dialog, 0)
        gtk_alert_dialog_set_default_button(dialog, 0)
        let choice = Choice { index in
            switch index {
            case 1: chosen(true)
            case 2: chosen(false)
            default: break
            }
        }
        gtk_alert_dialog_choose(dialog, parent, nil, onChosen, Unmanaged.passRetained(choice).toOpaque())
        g_object_unref(UnsafeMutableRawPointer(dialog))
    }

    /// What to do with the index of the button chosen.
    private final class Choice {
        let chosen: (Int32) -> Void

        init(_ chosen: @escaping (Int32) -> Void) {
            self.chosen = chosen
        }
    }

    private static let onChosen: GAsyncReadyCallback = { source, result, data in
        guard let data else { return }
        let choice = Unmanaged<Choice>.fromOpaque(data).takeRetainedValue()
        // The error is not read: a dismissed dialog answers the cancel button's
        // index, and there is nothing else an alert can fail with that would
        // change what to do — which is nothing.
        let index = gtk_alert_dialog_choose_finish(OpaquePointer(source), result, nil)
        choice.chosen(index)
    }
}
