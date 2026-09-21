import Testing

@testable import SkrepkaLinuxUI

@Suite("Appearance portal parsing")
struct AppearanceParserTests {
    @Test("ReadOne and deprecated Read variant depths both parse")
    func colorSchemeVariants() {
        #expect(
            AppearanceParser.colorScheme(from: .tuple([.variant(.uint32(1))])) == .dark)
        #expect(
            AppearanceParser.colorScheme(from: .tuple([.variant(.variant(.uint32(2)))])) == .light)
        #expect(AppearanceParser.colorScheme(from: .uint32(99)) == .noPreference)
    }

    @Test("Accent accepts in-range sRGB and rejects invalid portal data")
    func accent() {
        #expect(
            AppearanceParser.accent(
                from: .variant(.tuple([.double(0.1), .double(0.5), .double(1)])))
                == RGBColor(red: 0.1, green: 0.5, blue: 1)
        )
        #expect(
            AppearanceParser.accent(
                from: .tuple([.double(-0.1), .double(0.5), .double(1)])) == nil)
    }

    @Test("SettingChanged ignores unrelated namespaces")
    func settingChanged() {
        let accepted = AppearanceParser.settingChange(
            .tuple([
                .string("org.freedesktop.appearance"),
                .string("color-scheme"),
                .variant(.uint32(1)),
            ]))
        #expect(accepted?.0 == "color-scheme")
        #expect(accepted?.1 == .variant(.uint32(1)))
        #expect(
            AppearanceParser.settingChange(
                .tuple([
                    .string("org.example"), .string("color-scheme"), .variant(.uint32(1)),
                ])) == nil)
    }
}
