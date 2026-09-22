import Foundation
import SkrepkaIPC
import SkrepkaLinuxPlatform
import Testing

@testable import SkrepkaLinuxUI

@Suite("Settings: General and Diagnostics as drawn")
struct GeneralAndDiagnosticsStateTests {
    @Test("a bound shortcut is drawn as one keycap per key")
    func boundKeys() {
        let state = GeneralPaneState(
            shortcut: .bound("Meta+Shift+V"), autostart: AutostartStatus(isEnabled: true))
        #expect(state.shortcutKeys == ["Meta", "Shift", "V"])
        #expect(state.launchAtLogin)
    }

    /// A desktop's own words are kept — KDE's Meta, GNOME's Super. Only the
    /// portal's raw grammar, shown before the desktop has described the
    /// binding, is put into KDE's words.
    @Test(
        "the desktop's key names are kept; the portal's raw grammar is not",
        arguments: [
            ("Meta+Shift+V", ["Meta", "Shift", "V"]),
            ("LOGO+SHIFT+v", ["Meta", "Shift", "V"]),
            ("Super+V", ["Super", "V"]),
            ("Ctrl+Alt+M", ["Ctrl", "Alt", "M"]),
        ])
    func keyNames(trigger: String, keys: [String]) {
        #expect(GeneralPaneState.keys(trigger) == keys)
    }

    @Test(
        "keys are split only where the trigger is a plain chord",
        arguments: [
            ("Ctrl++", ["Ctrl", "+"]),
            ("Press <Super>v", ["Press <Super>v"]),
            ("  ", []),
            ("F12", ["F12"]),
        ])
    func keySplitting(trigger: String, keys: [String]) {
        #expect(GeneralPaneState.keys(trigger) == keys)
    }

    @Test("an unbound shortcut says so, with the portal's reason as a sentence")
    func unbound() {
        let state = GeneralPaneState(
            shortcut: .unbound("the prompt was dismissed"), autostart: AutostartStatus(isEnabled: false))
        #expect(state.shortcutKeys.isEmpty)
        #expect(state.shortcutValue == "Not set")
        #expect(state.shortcutSubtitle == "The prompt was dismissed.")
    }

    @Test("automatic paste follows the daemon and names the live mechanism")
    func automaticPaste() {
        let preferences = PreferencesFixtures.ready(
            PreferencesFixtures.settings(pasteAutomatically: false))
        let state = GeneralPaneState(
            shortcut: .connecting,
            autostart: AutostartStatus(isEnabled: false),
            preferences: preferences,
            pasteMechanism: .remoteDesktopPortal
        )
        #expect(!state.pasteAutomatically)
        #expect(state.isPasteEditable)
        #expect(state.pasteSubtitle.contains("ask once"))
        #expect(state.pasteSubtitle.contains("Ctrl+Shift+V"))
    }

    @Test("automatic paste is disabled for a daemon whose settings predate it")
    func automaticPasteNeedsVersionFive() {
        let old = PreferencesFixtures.settings(version: 4)
        let current = PreferencesFixtures.settings(version: 5)

        #expect(
            !GeneralPaneState(
                shortcut: .connecting,
                autostart: AutostartStatus(isEnabled: false),
                preferences: PreferencesFixtures.ready(old)
            ).isPasteEditable)
        #expect(
            GeneralPaneState(
                shortcut: .connecting,
                autostart: AutostartStatus(isEnabled: false),
                preferences: PreferencesFixtures.ready(current)
            ).isPasteEditable)
    }

    @Test("the picker action label follows the automatic-paste setting")
    func pickerActionLabel() {
        #expect(PickerFooter.actionLabel(isAutomatic: true) == "Paste")
        #expect(PickerFooter.actionLabel(isAutomatic: false) == "Copy")
    }

    @Test("a failed launch-at-login change puts the error where the subtitle was")
    func launchError() {
        let state = GeneralPaneState(
            shortcut: .connecting,
            autostart: AutostartStatus(isEnabled: false, error: "Skrepka could not write it."))
        #expect(state.launchSubtitle == "Skrepka could not write it.")
    }

    @Test("everything working is one green line, and the report is skrepka doctor's")
    func diagnosticsGood() {
        let document = PreferencesFixtures.diagnostics()
        let state = DiagnosticsPaneState(.ready(document), timeZone: .gmt)
        #expect(state.tone == .good)
        #expect(state.headline == "Everything Skrepka checks is working.")
        #expect(state.cards.map(\.title) == ["Clipboard", "Network", "Storage", "Daemon"])
        #expect(state.report == DoctorReport.text(document, timeZone: .gmt))
        #expect(state.placeholder == nil)
    }

    @Test("problems come first, and a blocked session is red")
    func diagnosticsProblems() {
        let document = PreferencesFixtures.diagnostics(problems: ["a", "b"], isBlocking: true)
        let state = DiagnosticsPaneState(.ready(document), timeZone: .gmt)
        #expect(state.headline == "2 things need attention.")
        #expect(state.tone == .bad)
        #expect(state.problems == ["a", "b"])
        #expect(state.cards.first?.notes == ["No data-control protocol."])
    }

    @Test("an extension submission accounts for native Wayland capture")
    func nativeWaylandCoverage() {
        let document = PreferencesFixtures.diagnostics(
            isXWaylandFallback: true, nativeWaylandCapture: .shellExtension)
        let state = DiagnosticsPaneState(.ready(document), timeZone: .gmt)
        let notes = state.cards.first?.notes ?? []

        #expect(notes.contains("The GNOME Shell extension covers native Wayland copies."))
        #expect(!notes.contains { $0.contains("invisible") })
    }

    @Test("with no report yet, Copy has nothing to copy")
    func diagnosticsLoading() {
        let state = DiagnosticsPaneState(.loading, timeZone: .gmt)
        #expect(state.report == nil)
        #expect(state.cards.isEmpty)
        #expect(state.placeholder != nil)
    }
}
