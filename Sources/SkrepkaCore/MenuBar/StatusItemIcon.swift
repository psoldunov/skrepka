// AppKit-only: draws an NSImage for the status item. Linux gets a tray icon in
// Phase 7, where the toolkit decides the shape rather than AppKit.
#if canImport(AppKit)

    import AppKit

    /// The menu bar mark: the app icon's paperclip, redrawn for a template image.
    ///
    /// Same path as ``PaperclipPath`` — the tile, the note cards and the metal
    /// shading have nowhere to go at 18pt, and a template image is alpha only, so
    /// all that survives is the silhouette. What does change is weight: three
    /// nested wires with a gap narrower than the wire between them need every
    /// point of that gap at menu bar sizes, so the mark is drawn at its own weight
    /// rather than boldened.
    public enum StatusItemIcon {
        /// Template images for a status item are measured in points. 18 is the
        /// usual height and leaves the button its own padding.
        public static let length: CGFloat = 18

        /// A black-and-clear template image. AppKit recolours it for the menu bar's
        /// appearance and for the highlighted state, so it must not carry colour.
        ///
        /// - Parameter badged: draws the attention mark, for when Skrepka cannot
        ///   capture. A template image is alpha only, so the badge cannot be the
        ///   usual red dot — it is a black dot in the corner the clip leaves empty,
        ///   which reads at 18pt in both menu bar appearances.
        public static func image(
            length: CGFloat = StatusItemIcon.length,
            badged: Bool = false
        ) -> NSImage {
            let image = NSImage(
                size: NSSize(width: length, height: length),
                flipped: false
            ) { rect in
                draw(in: rect, badged: badged)
                return true
            }
            image.isTemplate = true
            image.accessibilityDescription = badged ? "Skrepka — needs attention" : "Skrepka"
            return image
        }

        // MARK: - Geometry

        /// The badge sits in the mark's bottom-right corner, which is where the
        /// design box is empty — the clip runs bottom-left to top-right, so the
        /// usual top-right corner is the one place it is not. Measured in
        /// ``PaperclipPath``'s 1200-unit design box.
        ///
        /// A template image is alpha only, so the usual red disc is not available
        /// and the badge is a plain dot. What tells it apart from the wire is the
        /// gap: the nearest ink is some 355 units from this centre, well outside
        /// ``badgeClearance``, so nothing has to be cut out of the mark.
        private static let badgeCenter = CGPoint(x: 1010, y: 1075)

        /// Air reserved around the dot. Never drawn — it is unioned into the box
        /// being fitted, which scales the wire down and keeps the dot off the
        /// icon's edge. Move the badge inward and this is the number that has to
        /// move with it, because it is the only thing holding the gap open.
        ///
        /// Not private, and neither is ``badgeDisc(radius:)``: `StatusItemIconTests`
        /// checks this disc stays off the wire, which nothing else would notice.
        static let badgeClearance: CGFloat = 205
        private static let badgeDotRadius: CGFloat = 125

        static func badgeDisc(radius: CGFloat) -> CGPath {
            CGPath(
                ellipseIn: CGRect(
                    x: badgeCenter.x - radius,
                    y: badgeCenter.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ),
                transform: nil
            )
        }

        // MARK: - Drawing

        private static func draw(in rect: NSRect, badged: Bool) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let mark = PaperclipPath.outline()
            // The badge's clearance is included in the box being fitted, so a
            // badged icon scales its wire down rather than pushing the dot off the
            // edge.
            let bounds =
                badged
                ? mark.boundingBoxOfPath.union(badgeDisc(radius: badgeClearance).boundingBoxOfPath)
                : mark.boundingBoxOfPath

            // Leave half a point of air so the mark never touches the button edge.
            // Same transform the app and the icon renderer place the mark with, so
            // the three cannot disagree about the flip.
            guard
                var transform = PaperclipPath.transform(
                    fitting: bounds,
                    in: rect.insetBy(dx: 0.5, dy: 0.5)
                ),
                let fitted = mark.copy(using: &transform)
            else { return }

            // One fill for both: the outline is a single loop that never crosses
            // itself and the dot lands clear of it, so winding and even-odd draw
            // the same figure and the rule is not load-bearing here.
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(fitted)
            if badged, let dot = badgeDisc(radius: badgeDotRadius).copy(using: &transform) {
                context.addPath(dot)
            }
            context.fillPath()
        }
    }

#endif
