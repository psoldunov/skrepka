import Foundation
import SkrepkaSync

/// What the first bytes of a picture say about it: which format it is, and how
/// large it is shown.
///
/// The Linux daemon's whole knowledge of a copied picture file. It links no
/// image decoder — `PreviewDocument` in SkrepkaIPC says why — so it cannot
/// look at the pixels, but every format ``PictureFormat`` names states its
/// size in a header at a known place, and that is enough to call a row an
/// Image and put `2560 × 1440` under it. `skrepka-gui` does the decoding, on
/// GdkPixbuf, when the row is drawn.
public struct PictureHeader: Sendable, Hashable {
    public let format: PictureFormat
    /// Width and height as the picture is *shown*, or nil when the header does
    /// not say. A JPEG's EXIF orientation is applied, so a portrait phone photo
    /// reads `3024 × 4032` rather than the sensor's `4032 × 3024`. Always nil
    /// for TIFF, whose dimensions sit behind an offset table this does not walk
    /// — the same limit ``SkrepkaSync/ImageSignature/pixelSize(of:)`` has.
    public let displaySize: ClipItem.ImageSize?

    /// How much of a file is read to learn this. A JPEG's start-of-frame comes
    /// after its metadata, and a phone photo's EXIF block, embedded thumbnail
    /// and colour profile together fit well inside this; the other formats
    /// need a few dozen bytes.
    public static let length = 256 * 1024

    /// Nil when `bytes` do not begin like any picture ``PictureFormat`` knows —
    /// the ordinary answer for a copied document.
    public init?(_ bytes: Data) {
        let head = bytes.prefix(Self.length)
        guard let format = PictureFormat(sniffing: head) else { return nil }
        self.format = format
        displaySize = Self.displaySize(of: [UInt8](head), format: format)
    }

    private static func displaySize(of head: [UInt8], format: PictureFormat) -> ClipItem.ImageSize? {
        guard let stored = storedSize(of: head, format: format), stored.width > 0, stored.height > 0 else {
            return nil
        }
        if format == .jpeg, JPEGOrientation.swapsAxes(head) {
            return ClipItem.ImageSize(width: stored.height, height: stored.width)
        }
        return ClipItem.ImageSize(width: stored.width, height: stored.height)
    }

    /// The dimensions the header records, before any orientation.
    private static func storedSize(of head: [UInt8], format: PictureFormat) -> (width: Int, height: Int)? {
        switch format {
        case .png: ImageSignature.png.pixelSize(of: Data(head))
        case .jpeg: ImageSignature.jpeg.pixelSize(of: Data(head))
        case .gif: gifSize(head)
        case .bmp: bmpSize(head)
        case .webp: webPSize(head)
        case .tiff: nil
        }
    }

    /// The logical screen size, straight after the six-byte signature.
    private static func gifSize(_ head: [UInt8]) -> (width: Int, height: Int) {
        (PictureBytes.littleEndian(head, at: 6, count: 2), PictureBytes.littleEndian(head, at: 8, count: 2))
    }

    /// From the DIB header after the fourteen-byte file header. The 12-byte
    /// core header holds unsigned 16-bit sides; every later one holds signed
    /// 32-bit sides, with a negative height marking rows stored top-down.
    private static func bmpSize(_ head: [UInt8]) -> (width: Int, height: Int) {
        guard PictureBytes.littleEndian(head, at: 14, count: 4) != 12 else {
            return (
                PictureBytes.littleEndian(head, at: 18, count: 2),
                PictureBytes.littleEndian(head, at: 20, count: 2)
            )
        }
        let width = Int32(truncatingIfNeeded: PictureBytes.littleEndian(head, at: 18, count: 4))
        let height = Int32(truncatingIfNeeded: PictureBytes.littleEndian(head, at: 22, count: 4))
        return (Int(width), Int(height.magnitude))
    }

    /// From the first chunk after `RIFF····WEBP`, whose layout depends on which
    /// of the three kinds of WebP it is. Offsets are from the file's start;
    /// every chunk's payload begins at 20.
    private static func webPSize(_ head: [UInt8]) -> (width: Int, height: Int)? {
        guard head.count >= 30 else { return nil }
        switch Array(head[12..<16]) {
        case Array("VP8 ".utf8):
            // Lossy: a three-byte frame tag, the start code 9D 01 2A, then two
            // 14-bit sides, each under two bits of scaling.
            guard head[23..<26].elementsEqual([0x9D, 0x01, 0x2A]) else { return nil }
            return (
                PictureBytes.littleEndian(head, at: 26, count: 2) & 0x3FFF,
                PictureBytes.littleEndian(head, at: 28, count: 2) & 0x3FFF
            )
        case Array("VP8L".utf8):
            // Lossless: the signature byte 0x2F, then width − 1 and height − 1
            // packed as two 14-bit fields.
            guard head[20] == 0x2F else { return nil }
            let bits = PictureBytes.littleEndian(head, at: 21, count: 4)
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        case Array("VP8X".utf8):
            // Extended: four bytes of flags, then canvas width − 1 and
            // height − 1 as 24-bit fields.
            return (
                PictureBytes.littleEndian(head, at: 24, count: 3) + 1,
                PictureBytes.littleEndian(head, at: 27, count: 3) + 1
            )
        default:
            return nil
        }
    }
}
