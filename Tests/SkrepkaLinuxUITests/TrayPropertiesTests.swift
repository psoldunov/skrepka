import Testing

@testable import SkrepkaLinuxUI

@Suite("StatusNotifierItem properties")
struct TrayPropertiesTests {
    @Test("Healthy and problem states use the specified status and tooltip")
    func statuses() {
        let healthy = TrayProperties(problem: nil, pixmaps: [])
        let problem = TrayProperties(problem: "Clipboard access failed", pixmaps: [])
        #expect(healthy.value(named: "Status") == .string("Active"))
        #expect(problem.value(named: "Status") == .string("NeedsAttention"))
        #expect(
            problem.value(named: "ToolTip")
                == .tuple([
                    .string("skrepka-tray"),
                    .array(elementSignature: "(iiay)", values: []),
                    .string("Skrepka needs attention"),
                    .string("Clipboard access failed"),
                ]))
        #expect(healthy.value(named: "Menu") == .objectPath("/MenuBar"))
        #expect(healthy.value(named: "ItemIsMenu") == .boolean(false))
    }

    @Test("Native little-endian Cairo BGRA becomes network ARGB")
    func pixelByteOrder() {
        // Opaque, so un-premultiplying changes nothing and only the order is
        // under test.
        let bytes: [UInt8] = [0x33, 0x22, 0x11, 0xFF, 0xCC, 0xBB, 0xAA, 0xFF]
        let output = Self.convert(bytes)
        #if _endian(little)
            #expect(output == [0xFF, 0x11, 0x22, 0x33, 0xFF, 0xAA, 0xBB, 0xCC])
        #else
            #expect(output == bytes)
        #endif
    }

    /// Plasma reads the pixmap as straight alpha, so a premultiplied
    /// half-transparent white edge would arrive as half-transparent grey.
    @Test("A premultiplied edge pixel comes out straight")
    func unpremultiplies() {
        // Every byte 0x80, so the order cannot matter and only alpha does.
        let halfWhite: [UInt8] = [0x80, 0x80, 0x80, 0x80]
        #expect(Self.convert(halfWhite, width: 1) == [0x80, 0xFF, 0xFF, 0xFF])
        #expect(TrayPixmap.straight(0, 0) == 0)
        #expect(TrayPixmap.straight(0x11, 0x44) == 0x40)
    }

    private static func convert(_ bytes: [UInt8], width: Int = 2) -> [UInt8] {
        bytes.withUnsafeBufferPointer { buffer -> [UInt8] in
            guard let address = buffer.baseAddress else { return [] }
            return TrayPixmap.networkARGB(
                fromNativeARGB32: address, width: width, height: 1, stride: width * 4)
        }
    }
}
