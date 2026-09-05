// Renders the Skrepka app icon: a gem clip with eyes, a nod to the old Office
// assistant, drawn as vectors and rasterised once per iconset size so no size
// is a resampled copy of another.
//
//   swift scripts/make-icon.swift <output.iconset> [variant]
//   swift scripts/make-icon.swift --preview <directory>
//
// Variants exist so the palette can be compared side by side; the first one
// is what ships. Not part of any SwiftPM target — it lives in scripts/ so the
// package never tries to compile it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design space

/// Every coordinate below is in this space, with a top-left origin.
let canvas: CGFloat = 1024

let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient? {
    CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)
}

/// Fills `path` with a linear gradient between two design-space points.
func fill(_ ctx: CGContext, _ path: CGPath, _ grad: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(grad, start: from, end: to, options: [])
    ctx.restoreGState()
}

/// Draws `body` with a drop shadow. Geometry is given in design units; the
/// shadow is measured in base space, so it is scaled here rather than by the
/// current transform.
func withShadow(
    _ ctx: CGContext,
    _ scale: CGFloat,
    dy: CGFloat,
    blur: CGFloat,
    color: CGColor,
    _ body: () -> Void
) {
    ctx.saveGState()
    // Base space keeps a bottom-left origin, so a visually downward shadow is
    // a negative dy there even though the drawing space is flipped.
    ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color)
    body()
    ctx.restoreGState()
}

// MARK: - Variants

enum Finish {
    /// Rounded steel wire: bright top-left edge, shaded bottom-right.
    case chrome
    /// Flat two-tone graphite, one highlight, no specular.
    case flat
}

struct Variant {
    let name: String
    /// Tile gradient, top-left to bottom-right.
    let tile: [CGColor]
    /// A stack of note cards behind the clip.
    let cards: Bool
    let finish: Finish
    let wire: [CGColor]
    let brows: Bool
}

let variants: [Variant] = [
    Variant(
        name: "sand",
        tile: [rgb(0xF3E7D2), rgb(0xE4D0AE), rgb(0xCBAF85)],
        cards: true,
        finish: .flat,
        wire: [rgb(0x74829A), rgb(0x4E5B73), rgb(0x333D52)],
        brows: true
    ),
    Variant(
        name: "ink",
        tile: [rgb(0x38456B), rgb(0x232C4A), rgb(0x131829)],
        cards: true,
        finish: .chrome,
        wire: [rgb(0xFDFEFF), rgb(0xCBD5E6), rgb(0x74829E)],
        brows: true
    ),
    Variant(
        name: "graphite",
        tile: [rgb(0x4A5364), rgb(0x333B4A), rgb(0x1E2430)],
        cards: true,
        finish: .chrome,
        wire: [rgb(0xFDFEFF), rgb(0xCDD6E3), rgb(0x76839A)],
        brows: true
    ),
    Variant(
        name: "sage",
        tile: [rgb(0xDDE3D6), rgb(0xBFCAB6), rgb(0x94A38C)],
        cards: true,
        finish: .flat,
        wire: [rgb(0x6F7F82), rgb(0x47555A), rgb(0x2C383D)],
        brows: true
    ),
]

// MARK: - The gem clip

let clipCenterX: CGFloat = 512
/// Lift applied to the whole character, in design units.
let artOffsetY: CGFloat = -18
/// How much of the tile the character fills. macOS icons carry their weight
/// close to the edges; the clip on its own looked lost at 32pt without this.
let artScale: CGFloat = 1.18
let clipOuterHalfWidth: CGFloat = 210
let clipInnerHalfWidth: CGFloat = 105
let wireWidth: CGFloat = 48

/// One continuous wire, bent the way a gem clip actually is: a U at the bottom
/// of the inner loop, a tight U-turn at the top left stepping out to the outer
/// loop, a U at the bottom of the outer loop, and two free ends pointing up.
func clipWirePath() -> CGPath {
    let cx = clipCenterX
    let inner = clipInnerHalfWidth
    let outer = clipOuterHalfWidth
    let step = (outer - inner) / 2

    let path = CGMutablePath()
    path.move(to: CGPoint(x: cx + inner, y: 372))
    path.addArc(
        tangent1End: CGPoint(x: cx + inner, y: 700),
        tangent2End: CGPoint(x: cx - inner, y: 700),
        radius: inner
    )
    path.addArc(
        tangent1End: CGPoint(x: cx - inner, y: 700),
        tangent2End: CGPoint(x: cx - inner, y: 288),
        radius: inner
    )
    path.addArc(
        tangent1End: CGPoint(x: cx - inner, y: 288),
        tangent2End: CGPoint(x: cx - outer, y: 288),
        radius: step
    )
    path.addArc(
        tangent1End: CGPoint(x: cx - outer, y: 288),
        tangent2End: CGPoint(x: cx - outer, y: 790),
        radius: step
    )
    path.addArc(
        tangent1End: CGPoint(x: cx - outer, y: 790),
        tangent2End: CGPoint(x: cx + outer, y: 790),
        radius: outer
    )
    path.addArc(
        tangent1End: CGPoint(x: cx + outer, y: 790),
        tangent2End: CGPoint(x: cx + outer, y: 330),
        radius: outer
    )
    path.addLine(to: CGPoint(x: cx + outer, y: 330))
    return path
}

func strokedWire(_ width: CGFloat) -> CGPath {
    clipWirePath().copy(
        strokingWithWidth: width,
        lineCap: .round,
        lineJoin: .round,
        miterLimit: 10
    )
}

/// Strokes the wire centreline offset inside the silhouette, which is what
/// gives a flat stroke the roundness of a real wire.
func shadeWire(_ ctx: CGContext, dx: CGFloat, dy: CGFloat, width: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: dx, y: dy)
    ctx.addPath(clipWirePath())
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func drawClip(_ ctx: CGContext, _ variant: Variant, _ scale: CGFloat) {
    let silhouette = strokedWire(wireWidth)

    // A steel wire is lighter than the paper it holds, so it needs a rim to
    // stay a wire and not a hole in the cards.
    let plate = variant.finish == .chrome ? strokedWire(wireWidth + 7) : silhouette
    withShadow(ctx, scale, dy: 10, blur: 26, color: rgb(0x241A05, 0.32)) {
        ctx.addPath(plate)
        ctx.setFillColor(variant.finish == .chrome ? rgb(0x2B3444, 0.45) : variant.wire[1])
        ctx.fillPath()
    }

    guard let body = gradient(variant.wire, [0, 0.5, 1]) else { return }
    fill(ctx, silhouette, body, from: CGPoint(x: 300, y: 260), to: CGPoint(x: 730, y: 800))

    ctx.saveGState()
    ctx.addPath(silhouette)
    ctx.clip()
    switch variant.finish {
    case .chrome:
        shadeWire(ctx, dx: -7, dy: -8, width: wireWidth * 0.34, color: rgb(0xFFFFFF, 0.85))
        shadeWire(ctx, dx: 8, dy: 9, width: wireWidth * 0.30, color: rgb(0x3E4B60, 0.30))
    case .flat:
        shadeWire(ctx, dx: -6, dy: -7, width: wireWidth * 0.28, color: rgb(0xFFFFFF, 0.22))
    }
    ctx.restoreGState()
}

// MARK: - The face

struct Eye {
    let center: CGPoint
    let radius: CGFloat
}

let eyes = [
    Eye(center: CGPoint(x: 446, y: 438), radius: 72),
    Eye(center: CGPoint(x: 580, y: 426), radius: 65),
]

func drawEyes(_ ctx: CGContext, _ scale: CGFloat) {
    guard let white = gradient([rgb(0xFFFFFF), rgb(0xFFFFFF), rgb(0xDDE4EE)], [0, 0.55, 1]) else {
        return
    }

    for eye in eyes {
        let bounds = CGRect(
            x: eye.center.x - eye.radius,
            y: eye.center.y - eye.radius,
            width: eye.radius * 2,
            height: eye.radius * 2
        )
        let ball = CGPath(ellipseIn: bounds, transform: nil)

        withShadow(ctx, scale, dy: 6, blur: 16, color: rgb(0x241A05, 0.35)) {
            ctx.addPath(ball)
            ctx.setFillColor(rgb(0xFFFFFF))
            ctx.fillPath()
        }
        fill(
            ctx,
            ball,
            white,
            from: CGPoint(x: eye.center.x, y: bounds.minY),
            to: CGPoint(x: eye.center.x, y: bounds.maxY)
        )

        // Pupils sit high and slightly inward: a gaze up at whatever was just
        // copied reads friendlier than a straight-ahead stare.
        let pupil = CGPoint(x: eye.center.x + eye.radius * 0.16, y: eye.center.y - eye.radius * 0.12)
        let pupilRadius = eye.radius * 0.46
        ctx.setFillColor(rgb(0x151B27))
        ctx.fillEllipse(
            in: CGRect(
                x: pupil.x - pupilRadius,
                y: pupil.y - pupilRadius,
                width: pupilRadius * 2,
                height: pupilRadius * 2
            )
        )

        let glint = pupilRadius * 0.34
        ctx.setFillColor(rgb(0xFFFFFF, 0.92))
        ctx.fillEllipse(
            in: CGRect(
                x: pupil.x - pupilRadius * 0.42 - glint,
                y: pupil.y - pupilRadius * 0.46 - glint,
                width: glint * 2,
                height: glint * 2
            )
        )
    }
}

/// Brows do most of the expression work; they are drawn thick enough to survive
/// the 32pt rasterisation.
func drawBrows(_ ctx: CGContext) {
    let brows = CGMutablePath()
    brows.move(to: CGPoint(x: 384, y: 344))
    brows.addQuadCurve(to: CGPoint(x: 478, y: 328), control: CGPoint(x: 430, y: 312))
    brows.move(to: CGPoint(x: 546, y: 322))
    brows.addQuadCurve(to: CGPoint(x: 634, y: 344), control: CGPoint(x: 592, y: 310))

    ctx.addPath(brows)
    ctx.setStrokeColor(rgb(0x151B27))
    ctx.setLineWidth(20)
    ctx.setLineCap(.round)
    ctx.strokePath()
}

// MARK: - The tile and the cards

func drawTile(_ ctx: CGContext, _ variant: Variant) {
    let tile = CGPath(rect: CGRect(x: 0, y: 0, width: canvas, height: canvas), transform: nil)
    if let warm = gradient(variant.tile, [0, 0.55, 1]) {
        fill(ctx, tile, warm, from: .zero, to: CGPoint(x: canvas, y: canvas))
    }

    guard let glow = gradient([rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)], [0, 1]) else { return }
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 320, y: 210),
        startRadius: 0,
        endCenter: CGPoint(x: 320, y: 210),
        endRadius: 700,
        options: []
    )
    ctx.restoreGState()
}

/// Two note cards behind the clip — the history the clip is holding together.
func drawCards(_ ctx: CGContext, _ scale: CGFloat) {
    let sheets: [(rect: CGRect, angle: CGFloat, color: CGColor)] = [
        (CGRect(x: 300, y: 430, width: 420, height: 420), 6, rgb(0xF7EAD1)),
        (CGRect(x: 292, y: 418, width: 428, height: 428), -3, rgb(0xFFFFFF)),
    ]

    for sheet in sheets {
        let center = CGPoint(x: sheet.rect.midX, y: sheet.rect.midY)
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: sheet.angle * .pi / 180)
        ctx.translateBy(x: -center.x, y: -center.y)
        let card = CGPath(
            roundedRect: sheet.rect,
            cornerWidth: 26,
            cornerHeight: 26,
            transform: nil
        )
        withShadow(ctx, scale, dy: 12, blur: 30, color: rgb(0x3A2404, 0.3)) {
            ctx.addPath(card)
            ctx.setFillColor(sheet.color)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

// MARK: - Rasterisation

func renderIcon(size: Int, variant: Variant) -> CGImage? {
    guard
        let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    let scale = CGFloat(size) / canvas
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: scale, y: scale)
    // Flip into the top-left origin the artwork above is measured in.
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)

    drawTile(ctx, variant)

    // The character's ink sits low and small in its own coordinates; lift and
    // grow it about the tile centre so the tile reads as optically filled.
    ctx.translateBy(x: canvas / 2, y: canvas / 2 + artOffsetY)
    ctx.scaleBy(x: artScale, y: artScale)
    ctx.translateBy(x: -canvas / 2, y: -canvas / 2)
    if variant.cards {
        drawCards(ctx, scale)
    }
    drawClip(ctx, variant, scale)
    drawEyes(ctx, scale)
    if variant.brows {
        drawBrows(ctx)
    }

    return ctx.makeImage()
}

func write(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw IconError.message("no PNG encoder for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconError.message("failed writing \(url.path)")
    }
}

enum IconError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

func render(_ variant: Variant, sizes: [(name: String, pixels: Int)], into directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in sizes {
        guard let image = renderIcon(size: size.pixels, variant: variant) else {
            throw IconError.message("could not render \(size.name)")
        }
        try write(image, to: directory.appendingPathComponent("\(size.name).png"))
    }
}

// MARK: - Entry point

/// `iconutil` matches these names exactly; the set was confirmed by unpacking
/// an Apple-shipped .icns with `iconutil -c iconset`.
let iconsetSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

let arguments = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    let text = """
        usage: make-icon.swift <output.iconset> [variant]
               make-icon.swift --preview <directory>
        variants: \(variants.map(\.name).joined(separator: ", "))

        """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

do {
    switch arguments.first {
    case "--preview":
        guard arguments.count == 2 else { usage() }
        let directory = URL(fileURLWithPath: arguments[1])
        for variant in variants {
            try render(
                variant,
                sizes: [("\(variant.name)-1024", 1024), ("\(variant.name)-064", 64)],
                into: directory
            )
        }
        print("✓ previews in \(directory.path)")

    case .some(let path) where !path.hasPrefix("-"):
        let requested = arguments.count > 1 ? arguments[1] : variants[0].name
        guard let variant = variants.first(where: { $0.name == requested }) else {
            throw IconError.message("unknown variant \(requested)")
        }
        try render(variant, sizes: iconsetSizes, into: URL(fileURLWithPath: path))
        print("✓ rendered \(variant.name) at \(iconsetSizes.count) sizes")

    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
