import CGtk4

/// The row's right-click menu: Pin/Unpin, Copy as Plain Text, and Delete — the
/// macOS `RowContextMenu`, as a `GtkPopoverMenu` over a `GMenu` model.
///
/// The three items dispatch through one `GSimpleActionGroup` inserted on the
/// list, so the menu itself is rebuilt cheaply on each open (the Pin/Unpin label
/// depends on the row) while the actions live once. The popover is parented to
/// the row it opened over and unparented when it closes, which is what lets it
/// map as an `xdg_popup` on the layer-shell surface.
final class PickerContextMenu {
    /// The item handlers, given the hash of the row the menu opened over.
    var onPin: ((String) -> Void)?
    var onCopyPlain: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private let actions: UnsafeMutablePointer<GSimpleActionGroup>
    /// The row the open menu acts on, read by the actions when an item fires.
    private var targetHash: String?
    /// Whether a menu is on screen. The picker reads it so the focus change a
    /// popup causes, and the click that closes one, do not close the picker.
    private(set) var isOpen = false
    /// Called once a menu has closed, however it closed.
    var onClosed: (() -> Void)?

    init?() {
        guard let actions = g_simple_action_group_new() else { return nil }
        self.actions = actions
        add("pin") { [weak self] in self?.fire { $0.onPin } }
        add("copy-plain") { [weak self] in self?.fire { $0.onCopyPlain } }
        add("delete") { [weak self] in self?.fire { $0.onDelete } }
    }

    /// Makes the actions reachable as `picker.pin` and friends under `widget`.
    func installActions(on widget: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_insert_action_group(widget, "picker", skrepka_actions_as_group(actions))
    }

    /// Opens the menu over `rowWidget`, pointing at the click, for the entry
    /// `hash`. `pinned` chooses the Pin/Unpin label.
    func open(
        hash: String,
        pinned: Bool,
        over rowWidget: UnsafeMutablePointer<GtkWidget>,
        x: Double,
        y: Double
    ) {
        targetHash = hash
        guard let menu = g_menu_new(), let section = g_menu_new() else { return }
        g_menu_append(menu, pinned ? "Unpin" : "Pin", "picker.pin")
        g_menu_append(menu, "Copy as Plain Text", "picker.copy-plain")
        g_menu_append(section, "Delete", "picker.delete")
        g_menu_append_section(menu, nil, skrepka_menu_as_model(section))
        g_object_unref(UnsafeMutableRawPointer(section))
        guard let popoverWidget = gtk_popover_menu_new_from_model(skrepka_menu_as_model(menu)) else {
            g_object_unref(UnsafeMutableRawPointer(menu))
            return
        }
        g_object_unref(UnsafeMutableRawPointer(menu))
        present(popoverWidget, over: rowWidget, x: x, y: y)
    }

    private func present(
        _ popoverWidget: UnsafeMutablePointer<GtkWidget>,
        over rowWidget: UnsafeMutablePointer<GtkWidget>,
        x: Double,
        y: Double
    ) {
        guard let popover = skrepka_as_popover(popoverWidget) else { return }
        gtk_widget_set_parent(popoverWidget, rowWidget)
        gtk_popover_set_has_arrow(popover, 1)
        var rect = GdkRectangle(x: Int32(x), y: Int32(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(popover, &rect)
        // Unparent on close so the popover — and its one reference — is released
        // rather than left dangling on the row for the next open to stack on.
        GtkSignal.connect(UnsafeMutableRawPointer(popoverWidget), "closed") { [weak self] in
            self?.isOpen = false
            gtk_widget_unparent(popoverWidget)
            self?.onClosed?()
        }
        isOpen = true
        gtk_popover_popup(popover)
    }

    private func fire(_ handler: (PickerContextMenu) -> ((String) -> Void)?) {
        guard let hash = targetHash, let run = handler(self) else { return }
        run(hash)
    }

    private func add(_ name: String, _ run: @escaping () -> Void) {
        guard let action = g_simple_action_new(name, nil) else { return }
        PickerRowSignals.onActivate(skrepka_action_as_object(action), run)
        g_action_map_add_action(skrepka_actions_as_map(actions), skrepka_simple_action_as_action(action))
        g_object_unref(UnsafeMutableRawPointer(action))
    }
}
