import Foundation

/// Pasteboard type identifiers Skrepka reads and writes.
///
/// Spelled as raw strings so `SkrepkaCore` stays free of AppKit view types; the
/// values match `NSPasteboardType` constants in the macOS 26 SDK.
public enum PasteboardType {
    public static let string = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let rtfd = "com.apple.flat-rtfd"
    public static let html = "public.html"
    public static let url = "public.url"
    public static let fileURL = "public.file-url"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let pdf = "com.adobe.pdf"
    /// Verified against `UTCoreTypes.h` in the installed macOS SDK: `UTTypeJPEG`
    /// is documented there as `public.jpeg`, conforming to `public.image`.
    ///
    /// Here because Linux needs it more than macOS does — GTK4 registers a
    /// built-in `image/jpeg` serializer, so a JPEG-only copy is an ordinary
    /// thing to meet on that side and dropping it would be a hole in capture.
    /// It is a real UTI and macOS apps put it on the pasteboard too, so it goes
    /// in the one vocabulary rather than into a Linux-side table of its own.
    public static let jpeg = "public.jpeg"

    /// Ranked richest-first. The first match decides an entry's ``ClipKind``.
    public static let readOrder: [String] = [
        rtfd, rtf, html, fileURL, url, png, tiff, pdf, jpeg, string,
    ]

    /// The image representations, richest first.
    ///
    /// One list rather than the four copies of it this repository used to
    /// carry — ``ClipKind/identityTypes``, `ContentSize.imageByteCount`,
    /// `ThumbnailMaker.makePreview(fromImageBytesIn:)` and
    /// `CaptureRules.kind(for:)` all ranked the same three types independently,
    /// and a fourth type added to three of them is a picture that hashes as one
    /// thing, measures as another and previews as nothing.
    ///
    /// Lossless first, then vector, then lossy: an app that offers both a PNG
    /// and a JPEG of one picture is offering the PNG as the better copy.
    public static let imageReadOrder: [String] = [png, tiff, pdf, jpeg]

    /// The nspasteboard.org convention for naming the app content came from.
    /// Skrepka sets it on paste-back so other clipboard managers do not
    /// attribute restored content to Skrepka.
    public static let source = "org.nspasteboard.source"
}
