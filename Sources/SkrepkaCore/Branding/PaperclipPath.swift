// Core Graphics, not AppKit: CGPath, CGMutablePath and CGAffineTransform have no
// Linux equivalent, even though swift-corelibs-foundation does vend CGFloat,
// CGPoint, CGRect and CGSize. Excluded until OQ-12 settles whether the mark ports
// behind a portable path value type or is redrawn; either way that is Phase 7.
#if canImport(CoreGraphics)

    import CoreGraphics

    /// The Skrepka mark: a swirl paperclip, one continuous wire bent through three
    /// U-turns, with a semicircular cap on each free end.
    ///
    /// The artwork is an *outline* rather than a stroked centreline, because that is
    /// how it was drawn — reconstructing a centreline would mean guessing at bends
    /// the outline states exactly. The wire is 115.813 units wide in the 1200-unit
    /// design box, which is what fixes the size of the end caps.
    ///
    /// `scripts/paperclip.svg` is the same artwork in SVG form and is the design
    /// source. `scripts/make-icon.sh` compiles *this* file into the icon renderer,
    /// so the app, the menu bar and `AppIcon.icns` cannot drift apart.
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

        /// The mark at design-box scale, top-left origin: the coordinate table in
        /// the order the SVG states it — the outer edge from the bottom-left U-turn
        /// round to the outer free end, back along the inner edge, and so on inward
        /// to the inner free end.
        static func outline() -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 471.701, y: 1111.207))
            path.curve((677.774, 906.278), (838.970, 742.464), to: (1018.270, 566.612))
            path.curve((1077.465, 504.787), (1114.957, 444.275), to: (1130.742, 385.080))
            path.curve((1158.368, 273.373), (1115.893, 176.640), to: (1041.949, 100.943))
            path.curve((970.914, 29.909), (894.947, -3.635), to: (814.047, 0.312))
            path.curve((733.147, 4.259), (653.235, 45.038), to: (574.307, 122.649))
            path.line(to: (71.146, 627.780))
            path.roundCap(to: (154.020, 708.679))
            path.line(to: (657.180, 205.521))
            path.curve((708.810, 156.434), (770.250, 110.156), to: (840.685, 116.728))
            path.curve((948.002, 131.794), (1042.776, 263.144), to: (1018.272, 355.482))
            path.curve((987.201, 437.406), (944.367, 474.771), to: (885.083, 534.053))
            path.curve((704.742, 713.933), (564.127, 853.036), to: (388.830, 1028.332))
            path.curve((322.950, 1088.531), (280.344, 1104.830), to: (219.138, 1048.064))
            path.curve((187.567, 1016.493), (173.755, 985.580), to: (177.701, 955.325))
            path.curve((182.080, 920.024), (202.064, 895.608), to: (225.056, 872.452))
            path.line(to: (684.804, 412.702))
            path.curve((705.807, 391.662), (753.640, 351.277), to: (773.597, 369.293))
            path.curve((788.908, 404.814), (749.477, 438.718), to: (730.189, 458.086))
            path.line(to: (307.929, 880.345))
            path.roundCap(to: (388.828, 963.219))
            path.line(to: (813.060, 540.961))
            path.curve((886.129, 465.596), (938.626, 373.501), to: (856.469, 288.395))
            path.curve((765.607, 210.407), (669.886, 262.472), to: (601.930, 329.832))
            path.line(to: (142.182, 789.580))
            path.curve((94.827, 836.935), (67.859, 888.238), to: (61.283, 943.488))
            path.curve((56.095, 1020.942), (91.016, 1083.116), to: (138.236, 1130.939))
            path.curve((182.621, 1175.082), (230.572, 1199.533), to: (290.172, 1200.000))
            path.curve((361.828, 1197.131), (432.284, 1149.934), to: (471.701, 1111.207))
            path.closeSubpath()
            return path
        }
    }

    // MARK: - Table shorthand

    /// Terse spellings of the three commands the coordinate table uses, so one
    /// segment is one line and the table stays scannable against the SVG.
    extension CGMutablePath {
        fileprivate func line(to end: (CGFloat, CGFloat)) {
            addLine(to: CGPoint(x: end.0, y: end.1))
        }

        fileprivate func curve(
            _ control1: (CGFloat, CGFloat),
            _ control2: (CGFloat, CGFloat),
            to end: (CGFloat, CGFloat)
        ) {
            addCurve(
                to: CGPoint(x: end.0, y: end.1),
                control1: CGPoint(x: control1.0, y: control1.1),
                control2: CGPoint(x: control2.0, y: control2.1)
            )
        }

        /// Rounds off a free end: a half turn from where the wire's edge stopped,
        /// landing on the far edge at `end`. The source art cuts both ends square,
        /// which reads as a snapped-off stub rather than as wire.
        ///
        /// Clockwise in design-box numbers — the design box has a top-left origin,
        /// so this bulges away from the body of the clip at both ends.
        fileprivate func roundCap(to end: (CGFloat, CGFloat)) {
            let start = currentPoint
            let finish = CGPoint(x: end.0, y: end.1)
            let center = CGPoint(x: (start.x + finish.x) / 2, y: (start.y + finish.y) / 2)
            addArc(
                center: center,
                radius: hypot(finish.x - start.x, finish.y - start.y) / 2,
                startAngle: atan2(start.y - center.y, start.x - center.x),
                endAngle: atan2(finish.y - center.y, finish.x - center.x),
                clockwise: true
            )
        }
    }

#endif
