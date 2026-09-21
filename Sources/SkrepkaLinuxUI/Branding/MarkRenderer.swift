import CGtk4
import SkrepkaCore

/// Draws a ``MarkPath`` with Cairo — the Linux counterpart of `PaperclipPath`,
/// which renders the same value with Core Graphics.
///
/// This is what OQ-12's portable path IR was for: the coordinate table in
/// `PaperclipMark` is drawn by exactly one renderer per platform, so the app
/// icon, the macOS menu bar, the Linux tray and the picker's empty state are
/// one drawing rather than four that could drift.
///
/// ## Coordinates
///
/// The table is in the SVG's space — origin top left, y down — which is also
/// Cairo's, so nothing is flipped here. `PaperclipPath` flips because Core
/// Graphics is y-up. The arcs keep their meaning across the two: a
/// `clockwise` arc sweeps towards *decreasing* angles (see
/// `MarkArc.sweep`), which is `cairo_arc_negative`; the other direction is
/// `cairo_arc`.
///
/// `cairo` is the raw `cairo_t *` a GTK draw function or an image surface
/// hands out. Every function here is nonisolated and touches nothing but it.
enum MarkRenderer {
    /// A rectangle in the destination's own units — pixels for an image
    /// surface, logical pixels for a widget.
    struct Frame: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Where a path lands in a frame: scale first, then translate.
    struct Placement: Equatable {
        let scale: Double
        let translateX: Double
        let translateY: Double
    }

    /// Fills the Skrepka mark, fitted into `frame` and centred, in `color` at
    /// `alpha`.
    static func fillMark(
        _ cairo: OpaquePointer,
        in frame: Frame,
        color: RGBColor,
        alpha: Double = 1
    ) {
        let mark = PaperclipMark.outline()
        guard let placement = fit(mark, in: frame) else { return }
        cairo_save(cairo)
        cairo_translate(cairo, placement.translateX, placement.translateY)
        cairo_scale(cairo, placement.scale, placement.scale)
        cairo_new_path(cairo)
        addSegments(of: mark, to: cairo)
        cairo_restore(cairo)
        cairo_set_source_rgba(cairo, color.red, color.green, color.blue, alpha)
        // Winding rather than even-odd for the reason `StatusItemIcon` gives:
        // the outline is one loop that never crosses itself, so the two rules
        // draw the same figure, and winding is Cairo's default anyway.
        cairo_fill(cairo)
    }

    /// The placement that fits `path` into `frame`, aspect kept and centred —
    /// the arithmetic `PaperclipPath.transform(fitting:in:)` does, without the
    /// flip. Nil for a path with no area.
    static func fit(_ path: MarkPath, in frame: Frame) -> Placement? {
        guard let box = path.boundingBox, box.width > 0, box.height > 0 else { return nil }
        let scale = min(frame.width / box.width, frame.height / box.height)
        let midX = box.origin.x + box.width / 2
        let midY = box.origin.y + box.height / 2
        return Placement(
            scale: scale,
            translateX: frame.x + frame.width / 2 - midX * scale,
            translateY: frame.y + frame.height / 2 - midY * scale
        )
    }

    /// Appends `path` to Cairo's current path, in the path's own coordinates.
    static func addSegments(of path: MarkPath, to cairo: OpaquePointer) {
        for segment in path.segments {
            switch segment {
            case .move(let point):
                cairo_move_to(cairo, point.x, point.y)
            case .line(let point):
                cairo_line_to(cairo, point.x, point.y)
            case .curve(let control1, let control2, let end):
                cairo_curve_to(cairo, control1.x, control1.y, control2.x, control2.y, end.x, end.y)
            case .arc(let arc):
                if arc.clockwise {
                    cairo_arc_negative(
                        cairo, arc.center.x, arc.center.y, arc.radius, arc.startAngle, arc.endAngle)
                } else {
                    cairo_arc(cairo, arc.center.x, arc.center.y, arc.radius, arc.startAngle, arc.endAngle)
                }
            case .close:
                cairo_close_path(cairo)
            }
        }
    }
}
