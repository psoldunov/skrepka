import Foundation
import SkrepkaSync

/// A picture format a Linux row can show, recognised by its first bytes.
///
/// Wider than ``SkrepkaSync/ImageSignature`` on purpose, and kept apart from
/// it. That type decides what a *clipboard* may carry as a picture — the three
/// formats `RepresentationKeyMap` has rows for — and a match there is pasted as
/// one. This decides only what a row may *show*, and GdkPixbuf, which does the
/// drawing in `skrepka-gui`, reads GIF, BMP and WebP as well. A copied GIF
/// previews as a GIF and still pastes as the file it is.
///
/// The bytes rather than the file's name, for the reason `ImageSignature`
/// gives: an extension is a claim, and the signature is what the decoder will
/// actually meet. shared-mime-info answers from the same magic numbers, and
/// asking it needs GIO in a daemon that deliberately links none.
///
/// The cases are in the order the daemon prefers them when one entry holds
/// several — the order its `Preview` member has always followed.
public enum PictureFormat: String, Sendable, Hashable, CaseIterable {
    case png
    case jpeg
    case gif
    case bmp
    case tiff
    case webp

    public init?(sniffing bytes: Data) {
        if let signature = ImageSignature(sniffing: bytes) {
            self.init(signature)
            return
        }
        let head = [UInt8](bytes.prefix(Self.sniffedLength))
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) {
            self = .gif
        } else if Self.isWebP(head) {
            self = .webp
        } else if Self.isBMP(head) {
            self = .bmp
        } else {
            return nil
        }
    }

    init(_ signature: ImageSignature) {
        self =
            switch signature {
            case .png: .png
            case .jpeg: .jpeg
            case .tiff: .tiff
            }
    }

    /// The canonical media type, as the daemon names a picture on the bus.
    public var mediaType: String {
        "image/\(rawValue)"
    }

    /// Enough of a file to tell every format here apart.
    static let sniffedLength = 18

    /// A RIFF container whose form type is `WEBP`.
    private static func isWebP(_ head: [UInt8]) -> Bool {
        head.count >= 12 && head.starts(with: Array("RIFF".utf8))
            && head[8..<12].elementsEqual(Array("WEBP".utf8))
    }

    /// `BM` followed, fourteen bytes in, by the length of a DIB header that
    /// Windows actually defines.
    ///
    /// Two letters alone are no evidence at all — a text file beginning "BMW"
    /// would pass — so the header length has to be one a BMP writer can put
    /// there: `BITMAPCOREHEADER` at 12, `BITMAPINFOHEADER` at 40, the two Adobe
    /// extensions at 52 and 56, OS/2's second version at 64, `BITMAPV4HEADER`
    /// at 108 and `BITMAPV5HEADER` at 124.
    private static func isBMP(_ head: [UInt8]) -> Bool {
        guard head.count >= 18, head.starts(with: Array("BM".utf8)) else { return false }
        let headerLength = PictureBytes.littleEndian(head, at: 14, count: 4)
        return [12, 40, 52, 56, 64, 108, 124].contains(headerLength)
    }
}
