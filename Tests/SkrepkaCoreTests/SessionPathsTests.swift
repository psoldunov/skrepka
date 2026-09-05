// The XDG base directory rules are a freedesktop convention, so this is fenced to
// Linux with the type it exercises. macOS answers the same question with
// Application Support — see `HistoryStore.defaultStoreURL(bundleID:)`.
#if os(Linux)

    import Foundation
    import Testing

    @testable import SkrepkaCore

    @Suite("Session paths")
    struct SessionPathsTests {
        private let home = URL(filePath: "/home/tester", directoryHint: .isDirectory)

        @Test("XDG_DATA_HOME decides where data lives")
        func honoursTheDataHomeVariable() {
            let directory = SessionPaths.dataDirectory(
                environment: ["XDG_DATA_HOME": "/var/lib/somewhere"],
                homeDirectory: home
            )
            #expect(directory.path == "/var/lib/somewhere/skrepka")
        }

        /// Not `~/.skrepka`. A dotfile in `$HOME` survives no backup policy the
        /// user configured and is invisible to every tool that knows where data
        /// belongs.
        @Test("An unset variable falls back to ~/.local/share")
        func fallsBackToTheDocumentedDefault() {
            let directory = SessionPaths.dataDirectory(environment: [:], homeDirectory: home)
            #expect(directory.path == "/home/tester/.local/share/skrepka")
        }

        /// The specification: "If an implementation encounters a relative path in
        /// any of these variables it should consider the path invalid and ignore
        /// it." Honouring one would put the history wherever the daemon happened to
        /// be started from.
        @Test(
            "An empty or relative variable is ignored",
            arguments: ["", " ", "relative/path", "./here", "~/expanded-by-nobody"]
        )
        func ignoresAnInvalidVariable(value: String) {
            let directory = SessionPaths.dataDirectory(
                environment: [SessionPaths.dataHomeVariable: value],
                homeDirectory: home
            )
            #expect(directory.path == "/home/tester/.local/share/skrepka")
        }

        @Test("The history database sits inside the data directory")
        func theStoreLivesUnderTheDataDirectory() {
            let store = SessionPaths.historyStoreURL(environment: [:], homeDirectory: home)
            #expect(store.path == "/home/tester/.local/share/skrepka/skrepka.sqlite3")
        }
    }

#endif
