import Foundation

/// A picture format recognised by its first bytes, which is the only thing a
/// file's contents can be trusted to say about themselves.
///
/// A file name's extension is the sender's claim and says nothing about the
/// bytes behind it; the signature is what a decoder will actually meet. Limited
/// to the three formats ``RepresentationKeyMap`` can put on a clipboard, so a
/// match is always something a receiver can paste as a picture.
///
/// Platform-free on purpose: the Linux store has no image decoder in this
/// target, and the headers read by ``pixelSize(of:)`` are enough to give a
/// synced picture its dimensions there too.
public enum ImageSignature: String, Sendable, Hashable, CaseIterable {
    case png
    case jpeg
    case tiff

    public init?(sniffing bytes: Data) {
        let head = [UInt8](bytes.prefix(8))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            self = .png
        } else if head.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpeg
        } else if head.starts(with: [0x49, 0x49, 0x2A, 0x00]) || head.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            self = .tiff
        } else {
            return nil
        }
    }

    /// The media type the picture crosses the wire and a Linux clipboard under.
    public var canonical: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        case .tiff: "image/tiff"
        }
    }

    /// The macOS type a store and a pasteboard keep it under.
    public var storageType: String {
        // Every case has a row in the table; the fallback is unreachable and
        // spelled out only so this stays total without a force-unwrap.
        RepresentationKeyMap.uti(forCanonical: canonical) ?? canonical
    }

    /// Width and height in pixels, read from the header, or nil when the header
    /// does not say — always nil for TIFF, whose dimensions sit behind an
    /// offset table this does not walk.
    public func pixelSize(of bytes: Data) -> (width: Int, height: Int)? {
        let buffer = [UInt8](bytes)
        let size: (width: Int, height: Int)? =
            switch self {
            case .png: Self.pngSize(buffer)
            case .jpeg: Self.jpegSize(buffer)
            case .tiff: nil
            }
        guard let size, size.width > 0, size.height > 0 else { return nil }
        return size
    }

    /// `IHDR` is required to be the first chunk, so its fields sit at fixed
    /// offsets: eight bytes of signature, four of length, four of chunk type.
    private static func pngSize(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        guard bytes.count >= 24, bytes[12..<16].elementsEqual(Array("IHDR".utf8)) else { return nil }
        return (bigEndian(bytes, at: 16, count: 4), bigEndian(bytes, at: 20, count: 4))
    }

    /// Walks the marker segments to the first start-of-frame, which is where
    /// a JPEG states its size. The Huffman, arithmetic-coding and JPG markers
    /// share the SOF range and are skipped.
    private static func jpegSize(_ bytes: [UInt8]) -> (width: Int, height: Int)? {
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1
                continue
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                index += 2
                continue
            }
            let length = bigEndian(bytes, at: index + 2, count: 2)
            if isStartOfFrame(marker) {
                guard index + 8 < bytes.count else { return nil }
                return (bigEndian(bytes, at: index + 7, count: 2), bigEndian(bytes, at: index + 5, count: 2))
            }
            guard length >= 2 else { return nil }
            index += 2 + length
        }
        return nil
    }

    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
    }

    private static func bigEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> Int {
        bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
    }
}
