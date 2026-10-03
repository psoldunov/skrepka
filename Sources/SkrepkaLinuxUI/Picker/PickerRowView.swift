import CGtk4
import Foundation
import SkrepkaCore
import SkrepkaIPC

/// Builds one history row: the leading tile or thumbnail, the title and
/// subtitle, the pin marker and the Alt+N badge — the same anatomy as the macOS
/// `ClipRowView`, laid out with GTK boxes instead of an `HStack`.
///
/// A `GtkListBoxRow` rather than a bare child, so the list can read its index
/// back for Alt+N and attach the hover and context controllers to it. The row
/// decides nothing: ``PickerRowText`` has already built its strings and
/// ``ThumbnailCache`` its picture.
enum PickerRowView {
    /// A built row, and the subtitle line a transfer's progress bar replaces.
    struct Built {
        let row: UnsafeMutablePointer<GtkWidget>
        let transfer: PickerTransferSlot
    }

    /// - Parameters:
    ///   - texture: the decoded thumbnail, or nil until one arrives — an image
    ///     row shows a placeholder tile of the right height meanwhile, so the
    ///     list does not jump when the picture lands.
    ///   - metrics: the row height, the kind tile and the image preview, at the
    ///     interface size in force — the macOS row's 30pt tile and 84×48
    ///     preview at the design size.
    static func make(
        _ document: ClipDocument,
        text: PickerRowText,
        index: Int,
        texture: OpaquePointer?,
        metrics: PaletteMetrics
    ) -> Built? {
        guard let row = gtk_list_box_row_new(),
            let rowCast = skrepka_as_list_box_row(row),
            let body = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 11, "skrepka-rowbody"),
            let tile = tile(document, texture: texture, metrics: metrics),
            let column = textColumn(text)
        else { return nil }

        let isImageRow = document.hasPreview && !document.isConcealed
        gtk_widget_set_size_request(body, -1, metrics.rowHeight(isImage: isImageRow))
        gtk_widget_set_valign(tile, GTK_ALIGN_CENTER)
        Build.append(body, tile)
        Build.append(body, column.widget)
        if document.isPinned, let pin = Build.icon(pinNames, "skrepka-pin") {
            gtk_widget_set_valign(pin, GTK_ALIGN_CENTER)
            Build.append(body, pin)
        }
        if index < 9, let badge = badge(index + 1) {
            gtk_widget_set_valign(badge, GTK_ALIGN_CENTER)
            Build.append(body, badge)
        }
        gtk_list_box_row_set_child(rowCast, body)
        return Built(row: row, transfer: column.transfer)
    }

    // "view-pin-symbolic" draws a real pin in Breeze and Adwaita alike;
    // "starred-symbolic" stands in for a theme without one. The last is one of
    // the icons GTK carries built in, as pre-rendered PNGs: a host with no SVG
    // loader for gdk-pixbuf draws no themed symbolic icon at all, and a pinned
    // row must not end up wearing GTK's broken-image placeholder instead.
    private static let pinNames = ["view-pin-symbolic", "starred-symbolic", "bookmark-new-symbolic"]

    /// The title over the subtitle, both leading and truncated, filling the row
    /// — with the subtitle's stand-in for a transfer beside it, hidden.
    private static func textColumn(
        _ text: PickerRowText
    ) -> (widget: UnsafeMutablePointer<GtkWidget>, transfer: PickerTransferSlot)? {
        guard let column = Build.box(GTK_ORIENTATION_VERTICAL, spacing: 2),
            let title = Build.leadingLabel(text.title, "skrepka-title")
        else { return nil }
        gtk_widget_set_hexpand(column, 1)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        Build.append(column, title)
        guard let transfer = PickerTransferSlot.make(subtitle: text.subtitle, in: column) else { return nil }
        return (column, transfer)
    }

    /// The leading visual: a real preview for an image row with its picture
    /// decoded, a same-sized placeholder while it decodes, or the kind symbol.
    private static func tile(
        _ document: ClipDocument,
        texture: OpaquePointer?,
        metrics: PaletteMetrics
    ) -> UnsafeMutablePointer<GtkWidget>? {
        let names = PickerIconName.names(kind: document.kind, isConcealed: document.isConcealed)
        if document.hasPreview, !document.isConcealed {
            if let texture { return preview(texture, size: metrics.previewSize) }
            return placeholder(names, size: metrics.previewSize)
        }
        if !document.isConcealed, ClipKind(rawValue: document.kind) == .file {
            return fileTile(name: document.preview, side: metrics.tileSide)
        }
        return symbolTile(names, side: metrics.tileSide)
    }

    /// A file row's tile, its icon guessed from the file name's type so a `.zip`
    /// and a `.png` look different — falling back to the generic document glyph,
    /// which is a GTK built-in and so always renders.
    private static func fileTile(name: String, side: Int32) -> UnsafeMutablePointer<GtkWidget>? {
        guard let box = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "skrepka-tile"),
            let widget = gtk_image_new(), let image = skrepka_as_image(widget)
        else { return nil }
        let first = name.split(separator: ",", maxSplits: 1).first.map(String.init) ?? name
        skrepka_image_set_file_icon(
            image, first.trimmingCharacters(in: .whitespaces), "text-x-generic-symbolic")
        gtk_widget_set_size_request(box, side, side)
        centre(widget, in: box)
        return box
    }

    /// The picture, cover-cropped into a tile of exactly `size` — the macOS
    /// row's fixed preview frame, however wide or tall the picture is.
    ///
    /// A size request is only a minimum. A `GtkPicture` asks for the row's
    /// height times the picture's aspect ratio, and the row's box hands it that
    /// much, so a long screenshot came out as a tile half the panel wide. The
    /// picture is therefore an *overlay child* of a `GtkOverlay` with no main
    /// child: the overlay leaves overlay children out of its measurement, so it
    /// asks for its size request and nothing more, and stretches a filling
    /// overlay child across all of it. `can-shrink` keeps the picture's own
    /// minimum at zero, so it is laid out at the tile and never larger.
    private static func preview(
        _ texture: OpaquePointer, size: (width: Int32, height: Int32)
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let frame = gtk_overlay_new(), let overlay = skrepka_as_overlay(frame),
            let widget = gtk_picture_new(), let picture = skrepka_as_picture(widget)
        else { return nil }
        gtk_picture_set_paintable(picture, skrepka_texture_as_paintable(texture))
        gtk_picture_set_content_fit(picture, GTK_CONTENT_FIT_COVER)
        gtk_picture_set_can_shrink(picture, 1)
        gtk_widget_set_halign(widget, GTK_ALIGN_FILL)
        gtk_widget_set_valign(widget, GTK_ALIGN_FILL)
        gtk_overlay_add_overlay(overlay, widget)
        gtk_widget_set_size_request(frame, size.width, size.height)
        gtk_widget_set_overflow(frame, GTK_OVERFLOW_HIDDEN)
        gtk_widget_add_css_class(frame, "skrepka-thumb")
        return frame
    }

    private static func placeholder(
        _ names: [String], size: (width: Int32, height: Int32)
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let box = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "skrepka-thumb"),
            let icon = Build.icon(names)
        else { return nil }
        gtk_widget_set_size_request(box, size.width, size.height)
        centre(icon, in: box)
        return box
    }

    private static func symbolTile(_ names: [String], side: Int32) -> UnsafeMutablePointer<GtkWidget>? {
        guard let box = Build.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0, "skrepka-tile"),
            let icon = Build.icon(names)
        else { return nil }
        gtk_widget_set_size_request(box, side, side)
        centre(icon, in: box)
        return box
    }

    private static func centre(
        _ icon: UnsafeMutablePointer<GtkWidget>, in box: UnsafeMutablePointer<GtkWidget>
    ) {
        // A single child in a box is packed at the main-axis start, so `halign`
        // alone leaves the glyph against the left edge — which is what read as
        // "off centre". The icon must `expand` to be given the whole fixed tile
        // and then `align` centre within it, on both axes. The tile itself is
        // pinned to `expand: false` explicitly, so the child's expand does not
        // propagate up and stretch the tile in the row.
        gtk_widget_set_hexpand(icon, 1)
        gtk_widget_set_vexpand(icon, 1)
        gtk_widget_set_halign(icon, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(icon, GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(box, 0)
        gtk_widget_set_vexpand(box, 0)
        gtk_widget_set_halign(box, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(box, GTK_ALIGN_CENTER)
        Build.append(box, icon)
    }

    private static func badge(_ number: Int) -> UnsafeMutablePointer<GtkWidget>? {
        Build.label("Alt \(number)", "skrepka-badge")
    }
}
