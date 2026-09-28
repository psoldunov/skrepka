import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// `app.json`: the interface size survives a restart, and no file the user
/// could leave behind stops the app starting or draws it at a size it refuses.
@Suite("App preferences file")
struct AppPreferencesTests {
    private static func temporaryFile() -> AppPreferencesFile {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "skrepka-app-preferences-\(UUID().uuidString)", directoryHint: .isDirectory)
        return AppPreferencesFile(
            url: directory.appending(path: "nested/app.json", directoryHint: .notDirectory))
    }

    private static func write(_ text: String, to file: AppPreferencesFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    @Test("no file is the design size")
    func missingIsDefault() {
        #expect(Self.temporaryFile().load() == .default)
        #expect(AppPreferences.default.scale == .standard)
    }

    @Test("a saved size reads back, into a directory that did not exist")
    func roundTrip() throws {
        let file = Self.temporaryFile()
        let scale = try #require(InterfaceScale(percent: 125))
        #expect(file.save(AppPreferences(scale: scale)) == nil)
        #expect(file.load().scale == scale)
    }

    @Test(
        "a file that cannot be used reads as the design size",
        arguments: ["{}", "not json", #"{"version":1,"interfaceScale":500}"#, #"{"interfaceScale":"big"}"#])
    func unusableIsDefault(text: String) throws {
        let file = Self.temporaryFile()
        try Self.write(text, to: file)
        #expect(file.load().scale == .standard)
    }

    @Test("the file names its format")
    func writesItsVersion() throws {
        let file = Self.temporaryFile()
        #expect(file.save(.default) == nil)
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains(#""version" : 1"#))
        #expect(text.contains(#""interfaceScale" : 100"#))
    }

    @Test("a size between the offered ones is kept")
    func handEditedSizeIsKept() throws {
        let file = Self.temporaryFile()
        try Self.write(#"{"version":1,"interfaceScale":130}"#, to: file)
        #expect(file.load().scale.percent == 130)
    }

    @Test("a file that cannot be written says so, in words for the user")
    func unwritable() throws {
        let file = Self.temporaryFile()
        // A plain file where the directory should be.
        let parent = file.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: parent)
        let message = try #require(file.save(.default))
        #expect(message.hasPrefix("Skrepka could not save this to "))
    }
}

@Suite("Settings: the interface size as drawn")
struct InterfaceScalePaneTests {
    @Test("the design size is offered first and chosen by default")
    func defaultChoice() {
        let state = GeneralPaneState(shortcut: .connecting, autostart: AutostartStatus(isEnabled: false))
        #expect(state.interfaceScale.values == InterfaceScale.choices)
        #expect(state.interfaceScale.labels.first == "100%")
        #expect(state.interfaceScale.selected == 0)
        #expect(state.interfaceScaleSubtitle.contains("larger"))
    }

    @Test("the size in force is the one selected")
    func selectedChoice() throws {
        let scale = try #require(InterfaceScale(percent: 150))
        let state = GeneralPaneState(
            shortcut: .connecting,
            autostart: AutostartStatus(isEnabled: false),
            interfaceScale: InterfaceScaleStatus(scale: scale))
        #expect(state.interfaceScale.labels[state.interfaceScale.selected] == "150%")
    }

    @Test("a size from a hand edit is slotted in where it belongs")
    func customChoice() throws {
        let choice = GeneralPaneState.choice(try #require(InterfaceScale(percent: 130)))
        #expect(choice.values == [100, 110, 125, 130, 150, 175, 200])
        #expect(choice.values[choice.selected] == 130)
    }

    @Test("a size that could not be saved says why")
    func saveError() {
        let state = GeneralPaneState(
            shortcut: .connecting,
            autostart: AutostartStatus(isEnabled: false),
            interfaceScale: InterfaceScaleStatus(scale: .standard, error: "Skrepka could not save this."))
        #expect(state.interfaceScaleSubtitle == "Skrepka could not save this.")
    }
}
