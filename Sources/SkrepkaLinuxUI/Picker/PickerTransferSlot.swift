import CGtk4
import Foundation

/// One row's subtitle line, and the progress bar that stands in for it while
/// the row's bytes arrive from a peer — the macOS row's `TransferBarView`.
///
/// Built into the row once and switched in place, so a transfer moving on
/// changes one bar and one label rather than rebuilding the list: the layer
/// surface re-configures on every rebuild, and a keystroke landing then can be
/// dropped (see `PickerController.apply(rows:)`).
///
/// Holds borrowed pointers: the widgets belong to the row, and the list forgets
/// every slot the moment it removes the rows they live in.
struct PickerTransferSlot {
    /// The subtitle label, shown whenever nothing is arriving.
    let subtitle: UnsafeMutablePointer<GtkWidget>
    /// The bar and its percentage, together, hidden until a transfer starts.
    private let line: UnsafeMutablePointer<GtkWidget>
    private let bar: OpaquePointer
    private let percent: OpaquePointer

    /// The two lines, stacked in `column`; the transfer line starts hidden.
    static func make(
        subtitle text: String,
        in column: UnsafeMutablePointer<GtkWidget>
    ) -> PickerTransferSlot? {
        guard let subtitle = Build.leadingLabel(text, "skrepka-subtitle"),
            let line = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6, "skrepka-transfer"),
            let barWidget = gtk_progress_bar_new(), let bar = skrepka_as_progress_bar(barWidget),
            let percentWidget = Build.label("", "skrepka-subtitle"),
            let percent = skrepka_as_label(percentWidget)
        else { return nil }
        gtk_widget_set_hexpand(barWidget, 1)
        gtk_widget_set_valign(barWidget, GTK_ALIGN_CENTER)
        Build.append(line, barWidget)
        Build.append(line, percentWidget)
        gtk_widget_set_visible(line, 0)
        Build.append(column, subtitle)
        Build.append(column, line)
        return PickerTransferSlot(subtitle: subtitle, line: line, bar: bar, percent: percent)
    }

    /// Shows the bar at `fraction`, or the subtitle again when it is nil.
    func show(_ fraction: Double?) {
        guard let fraction else {
            gtk_widget_set_visible(line, 0)
            gtk_widget_set_visible(subtitle, 1)
            return
        }
        let clamped = min(max(fraction, 0), 1)
        gtk_progress_bar_set_fraction(bar, clamped)
        gtk_label_set_text(percent, "\(Int((clamped * 100).rounded(.down)))%")
        gtk_widget_set_visible(subtitle, 0)
        gtk_widget_set_visible(line, 1)
    }
}
