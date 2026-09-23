/// The EXIF orientation a JPEG carries, read out of its `APP1` segment.
///
/// A camera stores the sensor's rows as they came off it and records which way
/// up the phone was held beside them. Orientations 5 through 8 lay the stored
/// rows down the screen's columns, so the picture a person sees is the
/// transpose of the one the start-of-frame header measures — the reason
/// `ImageFileThumbnail.displaySize(of:)` swaps them on the Mac, and the reason
/// this exists for Linux, which has no ImageIO to ask.
enum JPEGOrientation {
    /// Whether the picture is shown with its width and height swapped.
    static func swapsAxes(_ bytes: [UInt8]) -> Bool {
        guard let orientation = value(in: bytes) else { return false }
        return (5...8).contains(orientation)
    }

    /// 1 through 8, or nil when the JPEG states none — which means 1.
    ///
    /// Walks the marker segments from the start of the file and stops at the
    /// start of scan, since every metadata segment comes before it.
    static func value(in bytes: [UInt8]) -> Int? {
        var index = 2
        while index + 4 <= bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            if marker == 0xDA || marker == 0xD9 { return nil }
            if marker == 0xFF {
                // A fill byte before the real marker.
                index += 1
                continue
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                index += 2
                continue
            }
            let length = PictureBytes.bigEndian(bytes, at: index + 2, count: 2)
            guard length >= 2 else { return nil }
            if marker == 0xE1, let orientation = exifOrientation(bytes, from: index + 4, length: length - 2) {
                return orientation
            }
            index += 2 + length
        }
        return nil
    }

    /// The `Orientation` tag of the TIFF structure an `Exif` segment holds.
    private static func exifOrientation(_ bytes: [UInt8], from start: Int, length: Int) -> Int? {
        let end = min(bytes.count, start + length)
        guard end - start >= 14, bytes[start..<(start + 6)].elementsEqual(Array("Exif".utf8) + [0, 0]) else {
            return nil
        }
        return orientation(inTIFF: Array(bytes[(start + 6)..<end]))
    }

    /// The `Orientation` tag in IFD0. Offsets count from the TIFF header, and
    /// the byte order is whichever the camera wrote — `II` or `MM`.
    private static func orientation(inTIFF tiff: [UInt8]) -> Int? {
        let isLittleEndian: Bool
        switch (tiff[0], tiff[1]) {
        case (0x49, 0x49): isLittleEndian = true
        case (0x4D, 0x4D): isLittleEndian = false
        default: return nil
        }
        func read(_ offset: Int, _ count: Int) -> Int {
            isLittleEndian
                ? PictureBytes.littleEndian(tiff, at: offset, count: count)
                : PictureBytes.bigEndian(tiff, at: offset, count: count)
        }
        guard read(2, 2) == 42 else { return nil }
        let directory = read(4, 4)
        for entry in 0..<read(directory, 2) {
            let offset = directory + 2 + entry * 12
            guard offset + 12 <= tiff.count else { return nil }
            // Tag 0x0112, one SHORT, held in the first two bytes of the value.
            guard read(offset, 2) == 0x0112 else { continue }
            guard read(offset + 2, 2) == 3 else { return nil }
            let value = read(offset + 8, 2)
            return (1...8).contains(value) ? value : nil
        }
        return nil
    }
}
