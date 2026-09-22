import CGtk4

/// The key hints along the bottom edge, and a gear that opens Settings — the
/// macOS `FooterHintsView`, with Alt where the Mac shows ⌘, plus the one thing
/// the Mac keeps in its menu bar and Linux has nowhere else to put.
///
/// The hints share their row with a place for an error: a copy that could not
/// be written says so here rather than closing the picker, so the row swaps the
/// hints for one sentence and swaps them back when the next keystroke clears it.
final class PickerFooter {
    let root: UnsafeMutablePointer<GtkWidget>
    private let hints: UnsafeMutablePointer<GtkWidget>
    private let action: UnsafeMutablePointer<GtkWidget>
    private let error: UnsafeMutablePointer<GtkWidget>

    /// Fires when the gear is clicked; the controller closes the picker and
    /// opens Settings.
    var onOpenSettings: (() -> Void)?

    private typealias Hint = (keys: [String], label: String)

    private static let hintData: [Hint] = [
        (["↑", "↓"], "Navigate"),
        (["↩"], actionLabel(isAutomatic: true)),
        (["Alt", "⇧", "↩"], "Plain text"),
        (["Alt", "P"], "Pin"),
        (["Esc"], "Close"),
    ]

    static func actionLabel(isAutomatic: Bool) -> String {
        isAutomatic ? "Paste" : "Copy"
    }

    init?() {
        guard let root = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "skrepka-footer"),
            let builtHints = Self.buildHints(),
            let error = Build.leadingLabel("", "skrepka-error"),
            let gear = gtk_button_new(),
            let gearIcon = Build.icon(["preferences-system-symbolic", "emblem-system-symbolic"])
        else { return nil }

        let hints = builtHints.row
        gtk_widget_set_hexpand(hints, 1)
        gtk_widget_set_halign(hints, GTK_ALIGN_START)
        gtk_widget_set_hexpand(error, 1)

        gtk_button_set_child(skrepka_as_button(gear), gearIcon)
        gtk_widget_add_css_class(gear, "skrepka-gear")
        gtk_widget_set_valign(gear, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(gear, "Settings")
        skrepka_set_accessible_label(gear, "Settings")
        gtk_widget_set_size_request(root, -1, 34)

        Build.append(root, hints)
        Build.append(root, error)
        Build.append(root, gear)

        self.root = root
        self.hints = hints
        self.action = builtHints.action
        self.error = error
        showError(nil)
        GtkSignal.connect(UnsafeMutableRawPointer(gear), "clicked") { [weak self] in
            self?.onOpenSettings?()
        }
    }

    func showPasteAutomatically(_ isAutomatic: Bool) {
        guard let action = skrepka_as_label(action) else { return }
        gtk_label_set_text(action, Self.actionLabel(isAutomatic: isAutomatic))
    }

    /// Shows `message` in place of the hints, or the hints again when nil.
    func showError(_ message: String?) {
        if let message, let label = skrepka_as_label(error) {
            gtk_label_set_text(label, message)
        }
        gtk_widget_set_visible(error, message == nil ? 0 : 1)
        gtk_widget_set_visible(hints, message == nil ? 1 : 0)
    }

    private static func buildHints() -> (row: GtkWidgetPointer, action: GtkWidgetPointer)? {
        guard let row = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 14) else { return nil }
        var action: GtkWidgetPointer?
        for (index, hint) in hintData.enumerated() {
            guard let built = buildHint(hint) else { return nil }
            if index == 1 { action = built.label }
            Build.append(row, built.group)
        }
        guard let action else { return nil }
        return (row, action)
    }

    private static func buildHint(
        _ hint: Hint
    ) -> (group: GtkWidgetPointer, label: GtkWidgetPointer)? {
        guard let group = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 5),
            let caps = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 3),
            let label = Build.label(hint.label, "skrepka-hint")
        else { return nil }
        for key in hint.keys {
            guard let cap = Build.label(key, "skrepka-keycap") else { return nil }
            gtk_widget_set_valign(cap, GTK_ALIGN_CENTER)
            Build.append(caps, cap)
        }
        gtk_widget_set_valign(caps, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        Build.append(group, caps)
        Build.append(group, label)
        return (group, label)
    }
}
