import CGtk4

/// The line at the top of the pane: the daemon's failure, sync being off, or
/// what the last action had to say.
final class SyncBanner {
    var onDismiss: (() -> Void)?

    let widget: GtkWidgetPointer
    private let message: GtkWidgetPointer
    private let detail: GtkWidgetPointer
    private let dismiss: GtkWidgetPointer

    init() throws {
        guard let box = GtkBuild.box(vertical: false, spacing: 12, classes: [SettingsStyle.banner]),
            let text = GtkBuild.box(vertical: true, spacing: 4),
            let message = GtkBuild.label("", classes: [SettingsStyle.bannerMessage], wraps: true),
            let detail = GtkBuild.label("", wraps: true),
            let dismiss = GtkBuild.button("Dismiss")
        else { throw SettingsError.widgetCreationFailed }
        // Copyable: the detail is usually a command to paste into a terminal —
        // `systemctl --user start skrepkad`.
        GtkBuild.makeCopyable(detail)
        gtk_widget_set_hexpand(text, 1)
        gtk_widget_set_valign(dismiss, GTK_ALIGN_CENTER)
        GtkBuild.append(message, to: text)
        GtkBuild.append(detail, to: text)
        GtkBuild.append(text, to: box)
        GtkBuild.append(dismiss, to: box)
        GtkBuild.setVisible(box, false)

        self.widget = box
        self.message = message
        self.detail = detail
        self.dismiss = dismiss
        GtkSignal.connect(UnsafeMutableRawPointer(dismiss), "clicked") { [weak self] in
            self?.onDismiss?()
        }
    }

    func render(_ banner: SyncPaneState.Banner?) {
        guard let banner else {
            GtkBuild.setVisible(widget, false)
            return
        }
        GtkBuild.setText(message, banner.message)
        // GTK's own `error` and `success` classes, which a theme colours when
        // it defines them and ignores when it does not — so this adds colour
        // where there is one to add and never depends on it.
        gtk_widget_remove_css_class(message, "error")
        gtk_widget_remove_css_class(message, "success")
        switch banner.tone {
        case .problem: gtk_widget_add_css_class(message, "error")
        case .success: gtk_widget_add_css_class(message, "success")
        case .info: break
        }
        GtkBuild.setText(detail, banner.detail ?? "")
        GtkBuild.setVisible(detail, banner.detail != nil)
        GtkBuild.setVisible(dismiss, banner.isDismissible)
        GtkBuild.setVisible(widget, true)
    }
}
