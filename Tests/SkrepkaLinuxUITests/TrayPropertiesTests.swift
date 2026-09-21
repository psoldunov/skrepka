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
        let bytes: [UInt8] = [0x33, 0x22, 0x11, 0x44, 0xCC, 0xBB, 0xAA, 0xDD]
        let output = bytes.withUnsafeBufferPointer { buffer -> [UInt8] in
            guard let address = buffer.baseAddress else { return [] }
            return TrayPixmap.networkARGB(fromNativeARGB32: address, width: 2, height: 1, stride: 8)
        }
        #if _endian(little)
            #expect(output == [0x44, 0x11, 0x22, 0x33, 0xDD, 0xAA, 0xBB, 0xCC])
        #else
            #expect(output == bytes)
        #endif
    }
}
