import AppKit

/// The menu bar mark: the app icon's gem clip with its eyes, redrawn for a
/// template image.
///
/// Deliberately not the same artwork as `AppIcon.icns`. At 18pt the wire needs
/// proportionally more weight to survive, the note cards and the metal shading
/// have nowhere to go, and a template image is alpha only — so the eyes keep
/// their pupils and lose their whites.
public enum StatusItemIcon {
    /// Template images for a status item are measured in points. 18 is the
    /// usual height and leaves the button its own padding.
    public static let length: CGFloat = 18

    /// A black-and-clear template image. AppKit recolours it for the menu bar's
    /// appearance and for the highlighted state, so it must not carry colour.
    ///
    /// - Parameter badged: draws the attention mark, for when Skrepka cannot
    ///   capture. A template image is alpha only, so the badge cannot be the
    ///   usual red dot — it is a gap punched out of the mark with a dot inside
    ///   it, which reads at 18pt in both menu bar appearances.
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

    /// The mark is laid out in a 100-unit box with a top-left origin, then
    /// scaled to fit whatever rect it is asked to draw into.
    private static let centerX: CGFloat = 50
    private static let outerHalfWidth: CGFloat = 34
    private static let innerHalfWidth: CGFloat = 15
    private static let wireWidth: CGFloat = 8
    private static let pupilRadius: CGFloat = 3

    /// Same bend order as the app icon: the inner loop turns at the bottom, a
    /// tight U-turn at the top left steps out to the outer loop, the outer loop
    /// turns at the bottom, and both free ends point up on the right.
    private static func wirePath() -> CGPath {
        let cx = centerX
        let inner = innerHalfWidth
        let outer = outerHalfWidth
        let step = (outer - inner) / 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx + inner, y: 30))
        path.addArc(
            tangent1End: CGPoint(x: cx + inner, y: 74),
            tangent2End: CGPoint(x: cx - inner, y: 74),
            radius: inner
        )
        path.addArc(
            tangent1End: CGPoint(x: cx - inner, y: 74),
            tangent2End: CGPoint(x: cx - inner, y: 24),
            radius: inner
        )
        path.addArc(
            tangent1End: CGPoint(x: cx - inner, y: 24),
            tangent2End: CGPoint(x: cx - outer, y: 24),
            radius: step
        )
        path.addArc(
            tangent1End: CGPoint(x: cx - outer, y: 24),
            tangent2End: CGPoint(x: cx - outer, y: 84),
            radius: step
        )
        path.addArc(
            tangent1End: CGPoint(x: cx - outer, y: 84),
            tangent2End: CGPoint(x: cx + outer, y: 84),
            radius: outer
        )
        path.addArc(
            tangent1End: CGPoint(x: cx + outer, y: 84),
            tangent2End: CGPoint(x: cx + outer, y: 26),
            radius: outer
        )
        path.addLine(to: CGPoint(x: cx + outer, y: 26))
        return path
    }

    /// The badge sits to the upper right of the wire, where the design box is
    /// empty. It is drawn as a hole punched through the mark with a dot inside
    /// it: a template image is alpha only, so the usual red disc is not
    /// available and the ring of clear pixels is what separates the badge from
    /// the wire at 18pt.
    private static let badgeCenter = CGPoint(x: 80, y: 20)
    private static let badgeRadius: CGFloat = 15
    private static let badgeDotRadius: CGFloat = 9

    /// The wire plus two pupils, as one fillable path. The pupils sit inside
    /// the inner loop's opening and never touch the wire, which is what keeps
    /// them readable once the whole thing is two pixels wide.
    private static func markPath() -> CGPath {
        let path = CGMutablePath()
        path.addPath(
            wirePath().copy(
                strokingWithWidth: wireWidth,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
        )
        for center in [CGPoint(x: centerX - 5.5, y: 41), CGPoint(x: centerX + 5.5, y: 39)] {
            path.addEllipse(
                in: CGRect(
                    x: center.x - pupilRadius,
                    y: center.y - pupilRadius,
                    width: pupilRadius * 2,
                    height: pupilRadius * 2
                )
            )
        }
        return path
    }

    private static func badgeDisc(radius: CGFloat) -> CGPath {
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
        let mark = markPath()
        // The badge is included in the box being fitted, so a badged icon
        // scales its wire down rather than clipping the badge off the edge.
        let bounds =
            badged
            ? mark.boundingBoxOfPath.union(badgeDisc(radius: badgeRadius).boundingBoxOfPath)
            : mark.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Leave half a point of air so the mark never touches the button edge.
        let target = rect.insetBy(dx: 0.5, dy: 0.5)
        let scale = min(target.width / bounds.width, target.height / bounds.height)
        // The negative y flips the top-left design box into the bottom-left
        // context the drawing handler hands over.
        var transform = CGAffineTransform(translationX: target.midX, y: target.midY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        guard let fitted = mark.copy(using: &transform) else { return }

        // Winding, not even-odd: the stroked wire outline overlaps itself at
        // every arc join, and even-odd would punch those overlaps into holes.
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(fitted)
        context.fillPath()

        guard badged else { return }
        drawBadge(in: context, transform: &transform)
    }

    /// Clears a disc out of whatever has been drawn, then fills a dot in the
    /// middle of it. Two passes rather than one path, so the mark keeps its
    /// winding fill.
    private static func drawBadge(in context: CGContext, transform: inout CGAffineTransform) {
        guard let ring = badgeDisc(radius: badgeRadius).copy(using: &transform),
            let dot = badgeDisc(radius: badgeDotRadius).copy(using: &transform)
        else { return }

        context.saveGState()
        context.setBlendMode(.clear)
        context.addPath(ring)
        context.fillPath()
        context.restoreGState()

        context.setFillColor(NSColor.black.cgColor)
        context.addPath(dot)
        context.fillPath()
    }
}
