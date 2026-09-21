import CGtk4
import SkrepkaCore

/// What fills the list area when there are no rows: the app's own mark for an
/// idle history, a magnifier for a search that found nothing, a warning when
/// the daemon cannot be reached — the three states of the macOS
/// `EmptyStateView`.
///
/// The idle state draws the paperclip through ``MarkRenderer`` — the same Cairo
/// renderer the tray uses, so the empty state and the tray icon are one
/// drawing. The mark's colour tracks the theme, so it is redrawn when the
/// appearance changes.
final class PickerEmptyState {
    /// Which of the three empty states to show.
    enum Kind: Equatable {
        case noHistory
        case noMatches
        case unreachable(headline: String, detail: String)
    }

    let root: UnsafeMutablePointer<GtkWidget>
    private let mark: UnsafeMutablePointer<GtkWidget>
    private let icon: UnsafeMutablePointer<GtkWidget>
    private let title: UnsafeMutablePointer<GtkWidget>
    private let detail: UnsafeMutablePointer<GtkWidget>
    private var isDark = true

    init?() {
        guard let root = Build.box(GTK_ORIENTATION_VERTICAL, spacing: 8, "skrepka-empty"),
            let mark = gtk_drawing_area_new(),
            let icon = gtk_image_new(),
            let title = Build.label("", "skrepka-empty-title"),
            let detail = Build.label("", "skrepka-empty-detail")
        else { return nil }

        gtk_widget_set_size_request(mark, 34, 34)
        gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
        gtk_image_set_pixel_size(skrepka_as_image(icon), 30)
        Self.centre(root)
        for child in [mark, icon, title, detail] {
            gtk_widget_set_halign(child, GTK_ALIGN_CENTER)
        }
        guard let detailLabel = skrepka_as_label(detail) else { return nil }
        gtk_label_set_wrap(detailLabel, 1)
        gtk_label_set_justify(detailLabel, GTK_JUSTIFY_CENTER)

        Build.append(root, mark)
        Build.append(root, icon)
        Build.append(root, title)
        Build.append(root, detail)

        self.root = root
        self.mark = mark
        self.icon = icon
        self.title = title
        self.detail = detail
        installMarkDraw()
    }

    private static func centre(_ root: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_set_valign(root, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(root, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(root, 1)
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_margin_top(root, 30)
        gtk_widget_set_margin_bottom(root, 30)
    }

    /// Redraws the mark for a dark or light desktop.
    func apply(isDark: Bool) {
        self.isDark = isDark
        gtk_widget_queue_draw(mark)
    }

    func show(_ kind: Kind) {
        switch kind {
        case .noHistory:
            present(
                showMark: true,
                title: "Nothing copied yet",
                detail: "Copy something and it will show up here.")
        case .noMatches:
            setIcon(["system-search-symbolic", "edit-find-symbolic"], warn: false)
            present(showMark: false, title: "No matches", detail: "Try a shorter search.")
        case .unreachable(let headline, let detailText):
            setIcon(["dialog-warning-symbolic", "emblem-important-symbolic"], warn: true)
            present(showMark: false, title: headline, detail: detailText)
        }
    }

    private func present(showMark: Bool, title titleText: String, detail detailText: String) {
        gtk_widget_set_visible(mark, showMark ? 1 : 0)
        gtk_widget_set_visible(icon, showMark ? 0 : 1)
        if let label = skrepka_as_label(title) { gtk_label_set_text(label, titleText) }
        if let label = skrepka_as_label(detail) { gtk_label_set_text(label, detailText) }
    }

    private func setIcon(_ names: [String], warn: Bool) {
        skrepka_image_set_icon_names(skrepka_as_image(icon), names.first, names.dropFirst().first, nil)
        if warn {
            gtk_widget_add_css_class(root, "skrepka-empty-warn")
        } else {
            gtk_widget_remove_css_class(root, "skrepka-empty-warn")
        }
    }

    private func installMarkDraw() {
        PickerRowSignals.setDrawFunc(mark) { [weak self] cairo, width, height in
            let dark = self?.isDark ?? true
            let frame = MarkRenderer.Frame(
                x: 0, y: 0, width: Double(width), height: Double(height))
            let colour = dark ? RGBColor(red: 1, green: 1, blue: 1) : RGBColor(red: 0, green: 0, blue: 0)
            MarkRenderer.fillMark(cairo, in: frame, color: colour, alpha: 0.4)
        }
    }
}
