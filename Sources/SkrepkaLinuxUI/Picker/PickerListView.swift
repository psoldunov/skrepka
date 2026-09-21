import CGtk4
import Foundation
import SkrepkaIPC

/// The scrolling list of rows.
///
/// Wraps a `GtkListBox` in a `GtkScrolledWindow` and rebuilds its rows from the
/// documents it is handed, attaching each row's hover, click and right-click so
/// the window never has to map a widget back to an entry — the row's own
/// callbacks carry its content hash. Selection is driven from outside, by index,
/// and revealed by nudging the scroll adjustment, because the window handles the
/// arrow keys itself and GTK's list does not scroll on a selection it did not
/// make.
final class PickerListView {
    let scroller: UnsafeMutablePointer<GtkWidget>
    private let scrollBox: OpaquePointer
    private let listWidget: UnsafeMutablePointer<GtkWidget>
    private let list: OpaquePointer
    private let menu: PickerContextMenu
    /// Row index → content hash, so the selected row's menu can be opened by
    /// key without threading the hash back out of the widget.
    private var rowHashes: [String] = []
    private var pinnedByHash: [String: Bool] = [:]

    /// A single click chooses the row.
    var onActivate: ((String) -> Void)?
    /// The pointer entering a row selects it — once the pointer has moved.
    var onHover: ((String) -> Void)?
    /// The pointer actually moved over the list, so hover may select now.
    var onPointerMoved: (() -> Void)?
    /// Context-menu items, given the row's hash.
    var onPin: ((String) -> Void)?
    var onCopyPlain: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    init?() {
        guard let listWidget = gtk_list_box_new(),
            let list = skrepka_as_list_box(listWidget),
            let scroller = gtk_scrolled_window_new(),
            let scrollBox = skrepka_as_scrolled_window(scroller),
            let menu = PickerContextMenu()
        else { return nil }
        gtk_list_box_set_selection_mode(list, GTK_SELECTION_SINGLE)
        gtk_widget_add_css_class(listWidget, "skrepka-list")
        gtk_scrolled_window_set_policy(scrollBox, GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(scrollBox, listWidget)
        gtk_widget_set_vexpand(scroller, 1)
        self.scroller = scroller
        self.scrollBox = scrollBox
        self.listWidget = listWidget
        self.list = list
        self.menu = menu
        wireMenu()
        wireMotion()
    }

    private func wireMenu() {
        menu.installActions(on: listWidget)
        menu.onPin = { [weak self] hash in self?.onPin?(hash) }
        menu.onCopyPlain = { [weak self] hash in self?.onCopyPlain?(hash) }
        menu.onDelete = { [weak self] hash in self?.onDelete?(hash) }
    }

    /// A list-wide motion controller arms hover: a pointer already inside when
    /// the surface maps emits a crossing but no motion, so the row under it is
    /// not selected until the pointer truly moves.
    private func wireMotion() {
        guard let motion = gtk_event_controller_motion_new() else { return }
        PickerRowSignals.onMotion(motion) { [weak self] in self?.onPointerMoved?() }
        gtk_widget_add_controller(listWidget, motion)
    }

    /// Rebuilds every row from `documents`.
    func setRows(
        _ documents: [ClipDocument],
        text: (ClipDocument) -> PickerRowText,
        texture: (ClipDocument) -> OpaquePointer?
    ) {
        gtk_list_box_remove_all(list)
        rowHashes = documents.map(\.contentHash)
        pinnedByHash = Dictionary(documents.map { ($0.contentHash, $0.isPinned) }) { first, _ in first }
        for (index, document) in documents.enumerated() {
            guard
                let row = PickerRowView.make(
                    document, text: text(document), index: index, texture: texture(document))
            else { continue }
            attach(row, hash: document.contentHash)
            gtk_list_box_append(list, row)
        }
    }

    /// Wires one row's hover, click and right-click to report its hash.
    private func attach(_ row: UnsafeMutablePointer<GtkWidget>, hash: String) {
        if let motion = gtk_event_controller_motion_new() {
            PickerRowSignals.onEnter(motion) { [weak self] in self?.onHover?(hash) }
            gtk_widget_add_controller(row, motion)
        }
        if let click = gtk_gesture_click_new() {
            gtk_gesture_single_set_button(skrepka_as_gesture_single(click), 1)
            PickerRowSignals.onPressed(click) { [weak self] _, _ in self?.onActivate?(hash) }
            gtk_widget_add_controller(row, click)
        }
        if let secondary = gtk_gesture_click_new() {
            gtk_gesture_single_set_button(skrepka_as_gesture_single(secondary), 3)
            PickerRowSignals.onPressed(secondary) { [weak self] xCoordinate, yCoordinate in
                guard let self else { return }
                self.menu.open(
                    hash: hash,
                    pinned: self.pinnedByHash[hash] ?? false,
                    over: row,
                    x: xCoordinate,
                    y: yCoordinate)
            }
            gtk_widget_add_controller(row, secondary)
        }
    }

    /// Opens the context menu on the selected row — the keyboard path to it.
    func openMenuForSelection() {
        guard let row = gtk_list_box_get_selected_row(list), let rowWidget = skrepka_row_as_widget(row)
        else { return }
        let index = Int(gtk_list_box_row_get_index(row))
        guard rowHashes.indices.contains(index) else { return }
        let hash = rowHashes[index]
        menu.open(hash: hash, pinned: pinnedByHash[hash] ?? false, over: rowWidget, x: 24, y: 24)
    }

    func select(index: Int?) {
        guard let index, let row = gtk_list_box_get_row_at_index(list, Int32(index)) else {
            gtk_list_box_unselect_all(list)
            return
        }
        gtk_list_box_select_row(list, row)
        reveal(row)
    }

    func scrollToTop() {
        guard let adjustment = gtk_scrolled_window_get_vadjustment(scrollBox) else { return }
        gtk_adjustment_set_value(adjustment, gtk_adjustment_get_lower(adjustment))
    }

    /// Scrolls the least amount that brings `row` fully into view.
    private func reveal(_ row: UnsafeMutablePointer<GtkListBoxRow>) {
        guard let rowWidget = skrepka_row_as_widget(row),
            let adjustment = gtk_scrolled_window_get_vadjustment(scrollBox)
        else { return }
        var bounds = graphene_rect_t()
        guard gtk_widget_compute_bounds(rowWidget, listWidget, &bounds) != 0 else { return }
        let top = Double(bounds.origin.y)
        let height = Double(bounds.size.height)
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        if top < value {
            gtk_adjustment_set_value(adjustment, top)
        } else if top + height > value + page {
            gtk_adjustment_set_value(adjustment, top + height - page)
        }
    }
}
