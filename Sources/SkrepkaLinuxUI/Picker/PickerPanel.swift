import CGtk4

/// The one glass panel: a search row, a hairline, the list or an empty state, a
/// hairline, and the footer — the macOS `PickerView`'s single surface, stacked
/// in a box.
///
/// Holds its four pieces and exposes them so the controller can wire their
/// callbacks; it owns only the switch between the list and the empty state,
/// which share the panel's middle. In a plain window the panel carries a margin
/// so the window behind it can be transparent and hold the shadow; the overlay
/// needs none — see ``PickerStyle`` and `PaletteWindow+Overlay.swift`.
final class PickerPanel {
    let root: UnsafeMutablePointer<GtkWidget>
    let searchBar: PickerSearchBar
    let list: PickerListView
    let footer: PickerFooter
    private let emptyState: PickerEmptyState
    /// Whether the middle says the daemon could not be reached, which the next
    /// reply has to replace even when its rows are the ones already held.
    private(set) var isShowingFailure = false

    init?() {
        guard let searchBar = PickerSearchBar(),
            let list = PickerListView(),
            let footer = PickerFooter(),
            let emptyState = PickerEmptyState(),
            let root = Build.box(GTK_ORIENTATION_VERTICAL, spacing: 0, "skrepka-panel"),
            let body = Build.box(GTK_ORIENTATION_VERTICAL, spacing: 0),
            let topLine = Self.hairline(),
            let bottomLine = Self.hairline()
        else { return nil }

        gtk_widget_set_vexpand(body, 1)
        Build.append(body, list.scroller)
        Build.append(body, emptyState.root)

        Build.append(root, searchBar.root)
        Build.append(root, topLine)
        Build.append(root, body)
        Build.append(root, bottomLine)
        Build.append(root, footer.root)

        self.searchBar = searchBar
        self.list = list
        self.footer = footer
        self.emptyState = emptyState
        self.root = root
        apply(.standard)
        showList()
    }

    /// Sizes the search row, the footer, the rows and the empty state for an
    /// interface size — the chrome to exactly ``PaletteMetrics/chromeHeight``,
    /// which is what the window sizes the panel by. Rows already on screen
    /// keep their size until the list is next rebuilt.
    func apply(_ metrics: PaletteMetrics) {
        gtk_widget_set_size_request(searchBar.root, -1, metrics.searchHeight)
        gtk_widget_set_size_request(footer.root, -1, metrics.footerHeight)
        list.metrics = metrics
        emptyState.apply(metrics.scale)
    }

    /// Shows the list, hiding the empty state.
    func showList() {
        isShowingFailure = false
        gtk_widget_set_visible(list.scroller, 1)
        gtk_widget_set_visible(emptyState.root, 0)
    }

    /// Shows an empty state, hiding the list.
    func showEmpty(_ kind: PickerEmptyState.Kind) {
        if case .unreachable = kind {
            isShowingFailure = true
        } else {
            isShowingFailure = false
        }
        emptyState.show(kind)
        gtk_widget_set_visible(list.scroller, 0)
        gtk_widget_set_visible(emptyState.root, 1)
    }

    /// Redraws the empty state's mark for a dark or light desktop.
    func apply(isDark: Bool) {
        emptyState.apply(isDark: isDark)
    }

    private static func hairline() -> UnsafeMutablePointer<GtkWidget>? {
        guard let line = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "skrepka-hairline") else {
            return nil
        }
        gtk_widget_set_size_request(line, -1, 1)
        return line
    }
}
