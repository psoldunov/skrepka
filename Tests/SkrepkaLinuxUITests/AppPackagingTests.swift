import Foundation
import Testing

@testable import SkrepkaLinuxUI

/// What ties the window to the files that ship beside it.
@Suite("Settings: packaging")
struct SettingsPackagingTests {
    /// A desktop matches a Wayland window to its launcher entry by the
    /// application ID, which is also the entry's file name — so a rename on
    /// one side alone leaves the window without its name and icon.
    ///
    /// `#filePath` finds the repository: this file is at
    /// `Tests/SkrepkaLinuxUITests/…`, so the root is two directories up.
    @Test("the application ID names the launcher entry that ships")
    func applicationIDNamesTheDesktopEntry() {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entry = root.appending(
            path: "packaging/desktop/\(SkrepkaApplication.applicationID).desktop",
            directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: entry.path))
    }
}
