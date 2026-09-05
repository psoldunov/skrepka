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

    /// Ranked richest-first. The first match decides an entry's ``ClipKind``.
    public static let readOrder: [String] = [
        rtfd, rtf, html, fileURL, url, png, tiff, pdf, string,
    ]

    /// The nspasteboard.org convention for naming the app content came from.
    /// Skrepka sets it on paste-back so other clipboard managers do not
    /// attribute restored content to Skrepka.
    public static let source = "org.nspasteboard.source"
}
