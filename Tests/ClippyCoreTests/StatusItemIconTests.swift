import AppKit
import Testing

@testable import ClippyCore

@Suite("Status item icon")
struct StatusItemIconTests {
    /// Rasterises the mark and reports what fraction of the box it inks.
    private func inkCoverage(length: CGFloat, scale: CGFloat) throws -> Double {
        let image = StatusItemIcon.image(length: length)
        var rect = NSRect(x: 0, y: 0, width: length, height: length)
        let source = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))

        let side = Int(length * scale)
        let context = try #require(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(source, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))

        let pixels = try #require(context.data)
        let alpha = (0..<side * side).map { index in
            pixels.load(fromByteOffset: index * 4 + 3, as: UInt8.self)
        }
        return Double(alpha.count { $0 > 127 }) / Double(side * side)
    }

    @Test("The mark is a template image at the size it was asked for")
    func isTemplateAtRequestedSize() {
        let image = StatusItemIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "Clippy")
        #expect(StatusItemIcon.image(length: 22).size == NSSize(width: 22, height: 22))
    }

    /// A wire drawn too heavy fills the box and reads as a blob; one drawn too
    /// light disappears in the menu bar. Neither shows up as a crash, so the
    /// coverage band is the only thing that catches it.
    @Test("The mark inks a menu-bar-sized share of its box")
    func coverageStaysInBand() throws {
        let coverage = try inkCoverage(length: 18, scale: 2)
        #expect(coverage > 0.12)
        #expect(coverage < 0.42)
    }

    @Test("The mark still has ink at 1x, where a menu bar point is one pixel")
    func survivesNonRetina() throws {
        #expect(try inkCoverage(length: 18, scale: 1) > 0.12)
    }
}
