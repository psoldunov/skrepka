import CGtk4

/// `row-selected` on a list box, whose handler takes the row as well as the
/// instance — a shape ``GtkSignal`` has no entry for.
///
/// The same retained-box arrangement ``GtkSignal`` describes: the box rides in
/// the signal's user data and GLib's closure notify releases it.
enum SidebarSignal {
    /// Calls `run` with the selected row's index, whenever the selection
    /// moves to a row.
    static func onRowSelected(_ list: OpaquePointer, _ run: @escaping (Int) -> Void) {
        skrepka_connect(
            UnsafeMutableRawPointer(list),
            "row-selected",
            unsafeBitCast(Box.onRowSelected, to: GCallback.self),
            Unmanaged.passRetained(Box(run)).toOpaque(),
            Box.onReleased
        )
    }

    private final class Box {
        let run: (Int) -> Void

        init(_ run: @escaping (Int) -> Void) {
            self.run = run
        }

        // Literal closures, for the reason `GtkSignal.Box` gives.

        typealias RowHandler =
            @convention(c) (gpointer?, UnsafeMutablePointer<GtkListBoxRow>?, gpointer?) -> Void

        static let onRowSelected: RowHandler = { _, row, data in
            guard let row, let data else { return }
            let box = Unmanaged<Box>.fromOpaque(data).takeUnretainedValue()
            box.run(Int(gtk_list_box_row_get_index(row)))
        }

        static let onReleased: GClosureNotify = { data, _ in
            guard let data else { return }
            Unmanaged<Box>.fromOpaque(data).release()
        }
    }
}
