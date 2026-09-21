import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// Launch at login as the text of `~/.config/autostart/…desktop`: off is
/// `Hidden=true` in the entry, per the freedesktop Autostart spec, not a
/// deleted file an upgrade would put back.
@Suite("Settings: the autostart entry")
struct AutostartFileTests {
    static let installed = """
        [Desktop Entry]
        Type=Application
        Name=Skrepka
        Exec=/home/deck/.local/bin/skrepka-gui --background
        X-GNOME-Autostart-enabled=true

        """

    @Test("no entry is off; an entry is on until it is hidden")
    func reading() {
        #expect(!AutostartFile.isEnabled(nil))
        #expect(AutostartFile.isEnabled(Self.installed))
        #expect(!AutostartFile.isEnabled(Self.installed + "Hidden=true\n"))
        #expect(!AutostartFile.isEnabled(Self.installed + "Hidden = true \n"))
        #expect(AutostartFile.isEnabled(Self.installed + "Hidden=false\n"))
    }

    @Test("only the Desktop Entry group's Hidden counts")
    func otherGroups() {
        let text = Self.installed + "[Desktop Action Settings]\nHidden=true\n"
        #expect(AutostartFile.isEnabled(text))
    }

    @Test("turning it off hides the entry and keeps everything else")
    func disabling() {
        let text = AutostartFile.disabling(Self.installed, executable: "/x")
        #expect(!AutostartFile.isEnabled(text))
        #expect(text.hasPrefix("[Desktop Entry]\nHidden=true\nType=Application"))
        #expect(text.contains("Exec=/home/deck/.local/bin/skrepka-gui --background"))
    }

    @Test("turning it off twice leaves one Hidden line")
    func disablingTwice() {
        let once = AutostartFile.disabling(Self.installed, executable: "/x")
        let twice = AutostartFile.disabling(once, executable: "/x")
        #expect(twice.components(separatedBy: "Hidden=").count == 2)
    }

    @Test("turning it back on removes every Hidden line and nothing else")
    func enabling() {
        let hidden = AutostartFile.disabling(Self.installed, executable: "/x") + "Hidden=true\n"
        let text = AutostartFile.enabling(hidden, executable: "/x")
        #expect(AutostartFile.isEnabled(text))
        #expect(text == Self.installed)
    }

    /// GNOME's own switch for an autostart entry writes this key rather than
    /// `Hidden`, and GNOME does not start an entry that has it false.
    @Test("GNOME's own off switch reads as off, and turning it on clears it")
    func gnomeSwitch() {
        let gnomeOff = Self.installed.replacingOccurrences(
            of: "X-GNOME-Autostart-enabled=true", with: "X-GNOME-Autostart-enabled=false")
        #expect(!AutostartFile.isEnabled(gnomeOff))
        let text = AutostartFile.enabling(gnomeOff, executable: "/x")
        #expect(AutostartFile.isEnabled(text))
        #expect(text == Self.installed)
    }

    @Test("with no entry, on writes a fresh one that starts this executable in the tray")
    func fresh() {
        let text = AutostartFile.enabling(nil, executable: "/opt/skrepka/bin/skrepka-gui")
        #expect(AutostartFile.isEnabled(text))
        #expect(text.contains("Exec=/opt/skrepka/bin/skrepka-gui --background\n"))
        #expect(!AutostartFile.isEnabled(AutostartFile.disabling(nil, executable: "/x")))
    }

    @Test("a path that needs quoting is quoted as the Desktop Entry spec says")
    func quoting() {
        #expect(AutostartFile.execQuoted("/home/deck/bin/skrepka-gui") == "/home/deck/bin/skrepka-gui")
        #expect(AutostartFile.execQuoted("/home/my deck/skrepka-gui") == "\"/home/my deck/skrepka-gui\"")
        #expect(AutostartFile.execQuoted("/a$b") == "\"/a\\$b\"")
    }

    @Test("the entry on disk round-trips through the switch")
    func onDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skrepka-autostart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = AutostartEntry(
            file: directory.appendingPathComponent("autostart").appendingPathComponent(
                AutostartFile.fileName),
            executable: "/usr/bin/skrepka-gui")
        #expect(!entry.status.isEnabled)
        #expect(entry.setEnabled(true) == AutostartStatus(isEnabled: true))
        #expect(entry.setEnabled(false) == AutostartStatus(isEnabled: false))
        let text = try String(contentsOf: entry.file, encoding: .utf8)
        #expect(text.contains("Hidden=true"))
    }
}
