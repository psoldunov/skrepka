// Core Graphics, not AppKit: CGPath, CGMutablePath and CGAffineTransform have no
// Linux equivalent, and neither does the `CoreGraphics` module that declares
// them — even though swift-corelibs-foundation does vend CGFloat, CGPoint,
// CGRect and CGSize (OQ-12).
//
// `#if canImport(CoreGraphics)` rather than `#if os(macOS)`, because it asks the
// question the compiler can actually answer and is the same guard that would let
// this file compile unchanged on any future Apple platform.
//
// What is *not* fenced is the artwork. The coordinate table moved to
// `PaperclipMark`, which is a platform-free `MarkPath`, and this file is now the
// Core Graphics renderer for it. That is the whole of OQ-12's answer: the mark
// ports, the drawing does not.
#if canImport(CoreGraphics)

    import CoreGraphics

    /// The Skrepka mark, as Core Graphics draws it.
    ///
    /// The artwork itself lives in ``PaperclipMark``. `scripts/make-icon.sh`
    /// compiles both files into the icon renderer, so the app, the menu bar and
    /// `AppIcon.icns` cannot drift apart.
    public enum PaperclipPath {
        /// The mark scaled to sit inside `rect`, keeping its aspect ratio and
        /// centred, with the design box's top-left origin flipped into the
        /// bottom-left origin Core Graphics draws in.
        ///
        /// - Parameter flipped: pass `false` when the destination context has
        ///   already been flipped to a top-left origin.
        public static func fitted(in rect: CGRect, flipped: Bool = true) -> CGPath? {
            let shape = outline()
            guard
                var transform = transform(
                    fitting: shape.boundingBoxOfPath,
                    in: rect,
                    flipped: flipped
                )
            else { return nil }
            return shape.copy(using: &transform)
        }

        /// Scales `bounds` to sit inside `rect`, keeping its aspect ratio and
        /// centred, and flips the design box's top-left origin into the bottom-left
        /// origin Core Graphics draws in.
        ///
        /// Spelled out separately from ``fitted(in:flipped:)`` for the caller that
        /// draws more than the mark: the menu bar's attention badge sits outside the
        /// silhouette, so the box being fitted is the mark's bounds unioned with the
        /// badge's, and the mark has to be placed with *this* transform rather than
        /// a second copy of the same arithmetic. Two copies can disagree about the
        /// flip, and a mirrored mark is not something an ink-coverage test can see.
        ///
        /// - Returns: `nil` for a degenerate `bounds`, which would otherwise scale
        ///   by infinity.
        /// - Parameter flipped: pass `false` when the destination context has
        ///   already been flipped to a top-left origin.
        public static func transform(
            fitting bounds: CGRect,
            in rect: CGRect,
            flipped: Bool = true
        ) -> CGAffineTransform? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }

            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            return CGAffineTransform(translationX: rect.midX, y: rect.midY)
                .scaledBy(x: scale, y: flipped ? -scale : scale)
                .translatedBy(x: -bounds.midX, y: -bounds.midY)
        }

        // MARK: - The outline

        /// ``PaperclipMark/outline()`` rendered to a `CGPath`.
        static func outline() -> CGPath {
            render(PaperclipMark.outline())
        }

        /// Replays a ``MarkPath`` into Core Graphics, segment for segment.
        ///
        /// Every case maps onto a `CGMutablePath` call that already exists, arcs
        /// included — which is why ``MarkSegment`` keeps arcs as arcs. Flattening
        /// them here would put a different approximation on each platform, and the
        /// end caps are exactly where that would show.
        static func render(_ path: MarkPath) -> CGPath {
            let cgPath = CGMutablePath()
            for segment in path.segments {
                switch segment {
                case .move(let point):
                    cgPath.move(to: point.cgPoint)
                case .line(let point):
                    cgPath.addLine(to: point.cgPoint)
                case .curve(let control1, let control2, let end):
                    cgPath.addCurve(
                        to: end.cgPoint, control1: control1.cgPoint, control2: control2.cgPoint)
                case .arc(let arc):
                    cgPath.addArc(
                        center: arc.center.cgPoint,
                        radius: CGFloat(arc.radius),
                        startAngle: CGFloat(arc.startAngle),
                        endAngle: CGFloat(arc.endAngle),
                        clockwise: arc.clockwise
                    )
                case .close:
                    cgPath.closeSubpath()
                }
            }
            return cgPath
        }
    }

    extension MarkPoint {
        fileprivate var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    }

#endif
