import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// Launch at login when the entry is not only the user's: a `.deb`, an `.rpm`
/// or a NixOS system puts it in `$XDG_CONFIG_DIRS/autostart`, where the
/// freedesktop Autostart spec says the user's own directory overrides it.
@Suite("Settings: the autostart entry across directories")
struct AutostartEntryTests {
    static let packaged = """
        [Desktop Entry]
        Type=Application
        Name=Skrepka
        Exec=skrepka-gui --background
        X-GNOME-Autostart-enabled=true

        """

    /// A user directory and two system directories under one temporary root,
    /// removed when the test ends.
    struct Layout {
        let root: URL
        let user: URL
        let systems: [URL]

        init() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("skrepka-autostart-\(UUID().uuidString)")
            self.root = root
            user = root.appendingPathComponent("home/autostart").appendingPathComponent(
                AutostartFile.fileName)
            systems = ["etc-xdg", "usr-etc-xdg"].map {
                root.appendingPathComponent("\($0)/autostart").appendingPathComponent(AutostartFile.fileName)
            }
        }

        func entry() -> AutostartEntry {
            AutostartEntry(file: user, systemFiles: systems, executable: "/usr/bin/skrepka-gui")
        }

        func write(_ text: String, to file: URL) throws {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("a system entry with no user entry reads as on")
    func systemEntryIsOn() throws {
        let layout = Layout()
        defer { layout.remove() }
        try layout.write(Self.packaged, to: layout.systems[1])
        #expect(layout.entry().status.isEnabled)
    }

    @Test("turning a system entry off hides it from the user's directory and leaves it alone")
    func disablingSystemEntry() throws {
        let layout = Layout()
        defer { layout.remove() }
        try layout.write(Self.packaged, to: layout.systems[0])
        let entry = layout.entry()

        #expect(entry.setEnabled(false) == AutostartStatus(isEnabled: false))
        let user = try String(contentsOf: layout.user, encoding: .utf8)
        #expect(user.hasPrefix("[Desktop Entry]\nHidden=true\n"))
        #expect(user.contains("Exec=skrepka-gui --background"))
        #expect(try String(contentsOf: layout.systems[0], encoding: .utf8) == Self.packaged)

        #expect(entry.setEnabled(true) == AutostartStatus(isEnabled: true))
        #expect(entry.status.isEnabled)
    }

    @Test("turning on a system entry that is already on writes nothing")
    func enablingSystemEntryIsQuiet() throws {
        let layout = Layout()
        defer { layout.remove() }
        try layout.write(Self.packaged, to: layout.systems[0])

        #expect(layout.entry().setEnabled(true) == AutostartStatus(isEnabled: true))
        #expect(!FileManager.default.fileExists(atPath: layout.user.path))
    }

    @Test("the user's entry wins over a system one")
    func userEntryWins() throws {
        let layout = Layout()
        defer { layout.remove() }
        try layout.write(Self.packaged, to: layout.systems[0])
        try layout.write(AutostartFile.disabling(Self.packaged, executable: "/x"), to: layout.user)
        #expect(!layout.entry().status.isEnabled)
    }

    @Test("the first system directory with the entry wins over later ones")
    func systemPrecedence() throws {
        let layout = Layout()
        defer { layout.remove() }
        try layout.write(AutostartFile.disabling(Self.packaged, executable: "/x"), to: layout.systems[0])
        try layout.write(Self.packaged, to: layout.systems[1])
        #expect(!layout.entry().status.isEnabled)
    }

    @Test("with no entry anywhere, on writes a fresh one for this executable")
    func freshEntry() throws {
        let layout = Layout()
        defer { layout.remove() }
        #expect(!layout.entry().status.isEnabled)
        #expect(layout.entry().setEnabled(true) == AutostartStatus(isEnabled: true))
        let user = try String(contentsOf: layout.user, encoding: .utf8)
        #expect(user.contains("Exec=/usr/bin/skrepka-gui --background\n"))
    }

    @Test("the directories come from XDG_CONFIG_HOME and XDG_CONFIG_DIRS, absolute paths only")
    func standardDirectories() {
        let entry = AutostartEntry.standard(environment: [
            "XDG_CONFIG_HOME": "/home/deck/.config",
            "XDG_CONFIG_DIRS": "/etc/xdg:relative/xdg::/run/current-system/sw/etc/xdg",
        ])
        #expect(entry.file.path == "/home/deck/.config/autostart/\(AutostartFile.fileName)")
        #expect(
            entry.systemFiles.map(\.path) == [
                "/etc/xdg/autostart/\(AutostartFile.fileName)",
                "/run/current-system/sw/etc/xdg/autostart/\(AutostartFile.fileName)",
            ])
    }

    @Test("with XDG_CONFIG_DIRS unset or empty, /etc/xdg is the system directory")
    func defaultSystemDirectory() {
        let expected = ["/etc/xdg/autostart/\(AutostartFile.fileName)"]
        #expect(AutostartEntry.standard(environment: [:]).systemFiles.map(\.path) == expected)
        #expect(
            AutostartEntry.standard(environment: ["XDG_CONFIG_DIRS": ""]).systemFiles.map(\.path) == expected)
    }

    /// A Nix build runs the app from a store path that garbage collection
    /// deletes, so its wrapper names the command a fresh entry should run.
    @Test("SKREPKA_GUI_EXECUTABLE names what a fresh entry runs, unless it is empty")
    func executableOverride() {
        #expect(
            AutostartEntry.standard(environment: ["SKREPKA_GUI_EXECUTABLE": "skrepka-gui"]).executable
                == "skrepka-gui")
        #expect(!AutostartEntry.standard(environment: ["SKREPKA_GUI_EXECUTABLE": ""]).executable.isEmpty)
    }
}
