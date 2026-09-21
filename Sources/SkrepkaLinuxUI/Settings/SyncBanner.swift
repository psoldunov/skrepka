import CGtk4

/// The line at the top of a pane: the daemon's failure, sync being off, or
/// what the last action had to say. The Sync pane's, and History's and
/// Privacy's too.
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
            let detail = GtkBuild.label("", classes: [SettingsStyle.secondary], wraps: true),
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
        // The tone colours the whole banner — red for a problem, green for a
        // success — in the palette's colours rather than the theme's.
        SettingsWidgets.setTone(widget, banner.tone == .info ? nil : SettingsStyle.tone(banner.tone))
        GtkBuild.setText(detail, banner.detail ?? "")
        GtkBuild.setVisible(detail, banner.detail != nil)
        GtkBuild.setVisible(dismiss, banner.isDismissible)
        GtkBuild.setVisible(widget, true)
    }
}
