import AppKit
import Foundation

/// Renders a small PNG preview for image entries.
///
/// Full image data lives in external storage and is never loaded to draw a
/// 44-point row; this is what the list actually shows.
public struct ThumbnailMaker: Sendable {
    /// Longest edge of the generated thumbnail, in pixels. Sized for a 2x
    /// display at the row height the picker uses.
    public static let maximumEdge: CGFloat = 256

    /// A row's preview: the scaled PNG and the original's pixel dimensions.
    public struct Preview: Sendable, Hashable {
        public let thumbnail: Data
        public let pixelSize: ClipItem.ImageSize?
    }

    public init() {}

    public func makePreview(from payload: ClipPayload) -> Preview? {
        let imageTypes = [PasteboardType.png, PasteboardType.tiff, PasteboardType.pdf]
        for type in imageTypes {
            guard let data = payload.data(forType: type), let image = NSImage(data: data) else {
                continue
            }
            guard let thumbnail = scaledPNG(from: image) else { return nil }
            return Preview(thumbnail: thumbnail, pixelSize: Self.pixelSize(of: image))
        }
        return nil
    }

    /// Pixel dimensions of the original, which is what the row subtitle shows.
    /// `NSImage.size` is in points; the bitmap rep carries the real pixels.
    static func pixelSize(of image: NSImage) -> ClipItem.ImageSize? {
        guard let rep = image.representations.first else { return nil }
        return ClipItem.ImageSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private func scaledPNG(from image: NSImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, Self.maximumEdge / max(size.width, size.height))
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))

        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(target.width),
                pixelsHigh: Int(target.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }

        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: target))

        return rep.representation(using: .png, properties: [:])
    }
}
