// Renders the Skrepka app icon: the paperclip mark on a rounded tile, drawn as
// vectors and rasterised once per iconset size so no size is a resampled copy
// of another.
//
// Built, not interpreted — scripts/make-icon.sh compiles this file together
// with Sources/SkrepkaCore/Branding/PaperclipPath.swift so the icon, the menu
// bar mark and the in-app artwork all come from one path. Run it through that
// script rather than `swift scripts/make-icon.swift`, which cannot see the
// second file.
//
//   make-icon <output.iconset> [variant]
//   make-icon --preview <directory>
//
// Variants exist so the palette can be compared side by side; the first one
// is what ships. Not part of any SwiftPM target — it lives in scripts/ so the
// package never tries to compile it into the app.

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
    let finish: Finish
    let wire: [CGColor]
}

/// Off-white and off-black, both directions. Nothing else is on the tile, so
/// the palette is the whole design decision: a neutral that does not fight the
/// wallpaper, and a clip dark or light enough to survive being 32 points wide.
let variants: [Variant] = [
    Variant(
        name: "paper",
        tile: [rgb(0xFCFBF8), rgb(0xF0EEE8), rgb(0xDEDBD3)],
        finish: .flat,
        wire: [rgb(0x4C4C52), rgb(0x2B2B30), rgb(0x151518)]
    ),
    Variant(
        name: "carbon",
        tile: [rgb(0x2C2C2F), rgb(0x1D1D20), rgb(0x101012)],
        finish: .chrome,
        wire: [rgb(0xFFFFFF), rgb(0xEDEBE6), rgb(0xBFBCB5)]
    ),
]

// MARK: - The tile

/// What survives macOS's own masking, in canvas units.
///
/// The Human Interface Guidelines say to hand macOS a *square* layer and let it
/// round the corners itself ("provide square layers so the system can apply
/// rounded corners"), and macOS 26 does that for a legacy `.icns` too: asking
/// `NSWorkspace` for the icon of a bundle carrying a full-bleed square
/// `AppIcon.icns` returns a squircle, inset, with a system-drawn rim and
/// shadow. Thresholding that answer's alpha gives 824 × 824 at +100 +100.
///
/// So the tile is drawn full bleed and carries no shadow and no corner radius
/// of its own — both would be applied twice — and everything that has to read
/// stays inside this rectangle.
let safeArea = CGRect(x: 100, y: 100, width: 824, height: 824)

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

// MARK: - The mark

/// Where the paperclip sits: square, so `PaperclipPath.fitted(in:)` centres the
/// mark's own bounding box inside it without cropping, and well inside
/// ``safeArea`` so the system's corner masking never reaches it. Lifted a
/// little, because the mark's ink sits low in its own box.
let markBox = safeArea.insetBy(dx: 112, dy: 112).offsetBy(dx: 0, dy: -12)

func drawClip(_ ctx: CGContext, _ variant: Variant, _ scale: CGFloat) {
    // `flipped: false`: the context has already been flipped into the top-left
    // origin the design space and PaperclipPath both use.
    guard let mark = PaperclipPath.fitted(in: markBox, flipped: false) else { return }

    // A light wire on a dark tile has nothing to end against, so chrome gets a
    // rim: the silhouette grown a little and filled darker, under the wire.
    let plate =
        variant.finish == .chrome
        ? mark.copy(
            strokingWithWidth: markBox.width / 80,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        : mark
    withShadow(ctx, scale, dy: 10, blur: 26, color: rgb(0x000000, 0.28)) {
        ctx.addPath(mark)
        ctx.addPath(plate)
        ctx.setFillColor(variant.finish == .chrome ? rgb(0x000000, 0.38) : variant.wire[1])
        ctx.fillPath()
    }

    guard let body = gradient(variant.wire, [0, 0.5, 1]) else { return }
    fill(
        ctx,
        mark,
        body,
        from: CGPoint(x: markBox.minX, y: markBox.minY),
        to: CGPoint(x: markBox.maxX, y: markBox.maxY)
    )

    ctx.saveGState()
    ctx.addPath(mark)
    ctx.clip()
    switch variant.finish {
    case .chrome:
        shadeEdge(ctx, mark, dx: -6, dy: -7, width: 16, color: rgb(0xFFFFFF, 0.85))
        shadeEdge(ctx, mark, dx: 7, dy: 8, width: 14, color: rgb(0x2A2A2E, 0.34))
    case .flat:
        shadeEdge(ctx, mark, dx: -5, dy: -6, width: 13, color: rgb(0xFFFFFF, 0.20))
    }
    ctx.restoreGState()
}

/// Runs a soft line along the mark's own boundary, offset out of the silhouette
/// so the clip it is drawn inside keeps only the half that falls on the wire.
/// That asymmetry is what gives a flat fill the roundness of a real wire.
func shadeEdge(
    _ ctx: CGContext,
    _ mark: CGPath,
    dx: CGFloat,
    dy: CGFloat,
    width: CGFloat,
    color: CGColor
) {
    ctx.saveGState()
    ctx.translateBy(x: dx, y: dy)
    ctx.addPath(mark)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
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
    drawClip(ctx, variant, scale)

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

func usage() -> Never {
    let text = """
        usage: make-icon <output.iconset> [variant]
               make-icon --preview <directory>
        variants: \(variants.map(\.name).joined(separator: ", "))

        """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

/// Compiled as a library so PaperclipPath can be linked in beside it, which
/// rules out top-level statements — hence an explicit entry point.
@main
enum IconTool {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
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
    }
}
