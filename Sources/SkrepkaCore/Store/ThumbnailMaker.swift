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

    /// A preview for anything the payload holds a picture of, or nil.
    ///
    /// Image bytes first, then the file the payload points at. The order is
    /// what keeps the common case off the disk: an app that puts both a
    /// `public.file-url` and a `public.png` on the pasteboard is previewed
    /// from the bytes it already handed over.
    ///
    /// The preview is a snapshot taken at copy time. Editing or deleting the
    /// file afterwards leaves the row showing the picture as it was, which is
    /// the same promise the rest of the history makes.
    public func makePreview(from payload: ClipPayload) -> Preview? {
        previewFromImageData(payload) ?? previewFromReferencedFile(payload)
    }

    private func previewFromImageData(_ payload: ClipPayload) -> Preview? {
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

    /// `public.file-url` carries the absolute URL string and nothing else, so
    /// the picture is read from the file itself.
    private func previewFromReferencedFile(_ payload: ClipPayload) -> Preview? {
        guard let url = payload.fileURL else { return nil }
        return ImageFileThumbnail.preview(ofFileAt: url, maximumEdge: Int(Self.maximumEdge))
    }

    /// Pixel dimensions of the original, which is what the row subtitle shows.
    /// `NSImage.size` is in points; the bitmap rep carries the real pixels.
    static func pixelSize(of image: NSImage) -> ClipItem.ImageSize? {
        guard let rep = image.representations.first else { return nil }
        return ClipItem.ImageSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private func scaledPNG(from image: NSImage) -> Data? {
        Self.scaledPNG(from: image, maximumEdge: Self.maximumEdge)
    }

    /// Draws `image` into a bitmap no larger than `maximumEdge` and encodes it.
    ///
    /// Never enlarges: a photograph drawn above its own resolution is a blurry
    /// copy of itself at several times the size.
    static func scaledPNG(from image: NSImage, maximumEdge: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maximumEdge / max(size.width, size.height))
        return png(
            from: image,
            targetSize: CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        )
    }

    /// Draws `image` at exactly `targetSize` and encodes it.
    ///
    /// Takes the size rather than a ceiling because ``FileIconStack`` must be
    /// able to ask for one *larger* than `NSImage.size`, which the scaling
    /// version refuses. A system icon measures 32 points and carries
    /// representations up to 512 pixels; drawing it at 128 picks the
    /// representation that fits, where capping it at its own point size would
    /// hand back a 32-pixel picture to put on a 48-point row.
    static func png(from image: NSImage, targetSize target: CGSize) -> Data? {
        guard target.width >= 1, target.height >= 1 else { return nil }

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
