import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads a row preview out of an image file on disk.
///
/// Copying a picture in Finder — or dragging one out of most apps — puts only a
/// `public.file-url` on the pasteboard. There are no image bytes to scale, so
/// the picture has to come off disk or the row shows a generic document icon.
///
/// ImageIO decodes straight to the size asked for, so a 100-megapixel original
/// never lands in memory whole. It is still a synchronous read of a file that
/// may sit on a slow or unresponsive volume, which is why callers reach this
/// through ``ThumbnailRenderer`` rather than from the main actor.
enum ImageFileThumbnail {
    /// A scaled PNG and the dimensions the picture is shown at, or nil when
    /// `url` is missing, unreadable, or not an image — which is the ordinary
    /// answer for a copied document or folder.
    static func preview(ofFileAt url: URL, maximumEdge: Int) -> ThumbnailMaker.Preview? {
        guard couldBeImage(url) else { return nil }

        // `kCGImageSourceShouldCache: false` — the source is read once and
        // dropped, so caching the decoded image would be pure waste.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
            CGImageSourceGetCount(source) > 0
        else { return nil }

        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Honour the EXIF orientation, or a portrait phone photo
                // previews on its side.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumEdge,
            ] as CFDictionary

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
            let thumbnail = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return nil }

        return ThumbnailMaker.Preview(thumbnail: thumbnail, pixelSize: displaySize(of: source))
    }

    /// Whether the file's own type says it is worth opening at all.
    ///
    /// A clip is `.file` whatever it points at, so without this a four-gigabyte
    /// video, a disk image or a folder is opened and probed purely to learn it
    /// is not a picture. `contentType` answers from the file system's metadata
    /// instead of the file's bytes.
    ///
    /// Deliberately generous: a file with no extension reports the generic
    /// `public.data`, which says nothing either way, so only a type that is
    /// definitely something else is rejected.
    private static func couldBeImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            // The file system would not say. Let ImageIO be the judge.
            return true
        }
        return type.conforms(to: .image) || type == .data || type == .item
    }

    /// The dimensions the picture is *shown* at, from the file's metadata, so
    /// the row subtitle can say `2560 × 1440` without decoding the full image.
    ///
    /// `kCGImagePropertyPixelWidth` counts pixels as stored, and EXIF
    /// orientation is carried separately. Orientations 5 through 8 lay the
    /// stored rows down the screen's columns, so both the thumbnail — which
    /// `kCGImageSourceCreateThumbnailWithTransform` rotates — and the picture
    /// the user sees are the transpose of what the metadata reports. Reporting
    /// the stored numbers put "4032 × 3024" under a portrait photo.
    private static func displaySize(of source: CGImageSource) -> ClipItem.ImageSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }

        // Absent orientation means 1, per CGImageProperties.h.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (5...8).contains(orientation) else {
            return ClipItem.ImageSize(width: width, height: height)
        }
        return ClipItem.ImageSize(width: height, height: width)
    }
}
