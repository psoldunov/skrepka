import CGtk4
import Testing

@testable import SkrepkaLinuxUI

@Suite("GVariant bridge")
struct DBusValueTests {
    @Test("Supported values round-trip through GVariant")
    func roundTrip() throws {
        let value = DBusValue.tuple([
            .string("hello"),
            .objectPath("/dev/soldunov/Skrepka"),
            .uint32(3),
            .dictionary(["enabled": .boolean(true)]),
            .array(elementSignature: "i", values: [.int32(1), .int32(2)]),
        ])
        let variant = try #require(value.makeVariant())
        g_variant_ref_sink(variant)
        defer { g_variant_unref(variant) }
        #expect(DBusValue.parse(variant) == value)
    }

    @Test("Container creation fails cleanly when a child is invalid")
    func invalidChildReturnsNil() {
        #expect(DBusValue.tuple([.string("owned"), .objectPath("not-a-path")]).makeVariant() == nil)
    }
}
