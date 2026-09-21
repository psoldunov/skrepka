import Testing

@testable import SkrepkaLinuxUI

@Suite("Tray menu")
struct TrayMenuTests {
    private let menu = TrayMenu(items: [
        .init(id: .init(rawValue: 1), label: "Open Skrepka"),
        .init(id: .init(rawValue: 2), label: "", separator: true),
        .init(id: .init(rawValue: 3), label: "Quit Skrepka", enabled: false),
    ])

    @Test("Layout is a dbusmenu root with variant-wrapped children")
    func layout() {
        let expected = DBusValue.tuple([
            .int32(0),
            .dictionary(["children-display": .string("submenu")]),
            .array(
                elementSignature: "v",
                values: [
                    .variant(
                        .tuple([
                            .int32(1),
                            .dictionary([
                                "label": .string("Open Skrepka"),
                                "enabled": .boolean(true),
                                "visible": .boolean(true),
                            ]),
                            .array(elementSignature: "v", values: []),
                        ])),
                    .variant(
                        .tuple([
                            .int32(2),
                            .dictionary([
                                "type": .string("separator"),
                                "visible": .boolean(true),
                            ]),
                            .array(elementSignature: "v", values: []),
                        ])),
                    .variant(
                        .tuple([
                            .int32(3),
                            .dictionary([
                                "label": .string("Quit Skrepka"),
                                "enabled": .boolean(false),
                                "visible": .boolean(true),
                            ]),
                            .array(elementSignature: "v", values: []),
                        ])),
                ]),
        ])
        #expect(menu.layout == expected)
    }

    @Test("Property filters return only requested names")
    func properties() {
        let values = menu.properties(
            for: .init(rawValue: 1),
            names: ["label"]
        )
        #expect(values == ["label": .string("Open Skrepka")])
        #expect(menu.properties(for: .init(rawValue: 99)) == nil)
    }
}
