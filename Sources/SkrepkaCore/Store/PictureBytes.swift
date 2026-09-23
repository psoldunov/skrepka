/// Fixed-width integers read out of a picture's header, bounds-checked.
///
/// Every reader here answers 0 past the end of `bytes` rather than trapping:
/// the bytes are whatever a copied file begins with, and a header cut short is
/// an ordinary thing to meet, not a programming error. A zero dimension is
/// already what every caller treats as "the header does not say".
enum PictureBytes {
    static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> Int {
        guard offset >= 0, offset + count <= bytes.count else { return 0 }
        return bytes[offset..<(offset + count)].reversed().reduce(0) { $0 << 8 | Int($1) }
    }

    static func bigEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> Int {
        guard offset >= 0, offset + count <= bytes.count else { return 0 }
        return bytes[offset..<(offset + count)].reduce(0) { $0 << 8 | Int($1) }
    }
}
