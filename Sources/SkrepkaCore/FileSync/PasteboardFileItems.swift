import Foundation

#if canImport(ImageIO)
    import ImageIO
    import UniformTypeIdentifiers
#endif

/// The pasteboard items a Mac writes for files received from a peer, one
/// dictionary of type → bytes per item. Pure; the app turns each dictionary
/// into an `NSPasteboardItem`.
///
/// **One item per file, each carrying one `public.file-url`**, the shape Finder
/// writes and the one `NSPasteboard.h` names as the replacement for the
/// deprecated `NSFilenamesPboardType`. ``ForeignFileGuard/clipboard(forFilesAt:from:)``
/// joins several URLs into one `text/uri-list`-style value, which is what a
/// Linux clipboard takes and what no Mac app reads as more than one file.
///
/// The first item also carries everything else the clipboard holds — the names
/// as text and, for a single picture, its bytes — so an app that takes a
/// picture or text rather than a file still gets one.
public enum PasteboardFileItems {
    /// The items for `clipboard`, first item first.
    ///
    /// A clipboard naming no file — the names fallback — is one item holding
    /// its payload as it is.
    ///
    /// - Parameter png: the PNG form of a picture held in another format, when
    ///   the payload has no PNG of its own. See ``pngTranscode(of:)``.
    public static func items(
        for clipboard: ForeignFileGuard.Clipboard,
        png: Data? = nil
    ) -> [[String: Data]] {
        guard let first = clipboard.fileURLs.first else { return [clipboard.payload.representations] }
        var head = clipboard.payload.representations
        head[PasteboardType.fileURL] = fileURLData(first)
        if let png, head[PasteboardType.png] == nil {
            head[PasteboardType.png] = png
        }
        let rest = clipboard.fileURLs.dropFirst().map { [PasteboardType.fileURL: fileURLData($0)] }
        return [head] + rest
    }

    /// The picture in `payload` that wants a PNG beside it, or nil when there
    /// is none or a PNG is already there.
    ///
    /// Messages, Slack and most editors read `public.png` and `public.tiff`
    /// from a pasteboard and pass over `public.jpeg`, so a synced photo pastes
    /// into them only once it is also a PNG.
    public static func pictureNeedingPNG(in payload: ClipPayload) -> Data? {
        guard payload.representations[PasteboardType.png] == nil else { return nil }
        return payload.representations[PasteboardType.jpeg]
    }

    private static func fileURLData(_ url: URL) -> Data {
        Data(url.absoluteString.utf8)
    }

    #if canImport(ImageIO)
        /// Most pixels a picture may declare and still be converted: 50 MP, a
        /// high-end camera's frame. The declared size is the sender's claim — a
        /// few hundred bytes of JPEG can declare 65535 × 65535 — and decoding
        /// that is gigabytes, so a larger claim pastes as JPEG and file alone.
        public static let pixelBudget = 50_000_000

        /// Longest edge the PNG is drawn at. A bound on the decode whatever the
        /// header says; larger pictures are scaled down to it.
        public static let maximumEdge = 8192

        /// `picture` re-encoded as PNG, upright, or nil when ImageIO cannot
        /// decode it or it declares more than `pixelBudget` pixels.
        ///
        /// Decodes the whole picture: call it off the main actor.
        public static func pngTranscode(of picture: Data, pixelBudget: Int = pixelBudget) -> Data? {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(picture as CFData, sourceOptions),
                let size = declaredSize(of: source),
                size.width > 0, size.height > 0,
                // Each edge first, so the product below cannot overflow.
                size.width <= pixelBudget, size.height <= pixelBudget,
                size.width * size.height <= pixelBudget
            else { return nil }
            // A thumbnail rather than the image itself: only the thumbnail call
            // applies the EXIF orientation, and a PNG has no orientation of its
            // own to carry it in.
            let options =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(max(size.width, size.height), maximumEdge),
                ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output as CFMutableData, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }

        /// The pixel size the header declares, read without decoding anything.
        private static func declaredSize(of source: CGImageSource) -> (width: Int, height: Int)? {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            return (width, height)
        }
    #endif
}
