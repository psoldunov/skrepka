// Where Skrepka keeps its files on Linux. Fenced to Linux because the XDG base
// directory specification is a freedesktop convention and macOS answers the same
// question with Application Support — see `HistoryStore.defaultStoreURL(bundleID:)`.
#if os(Linux)

    import Foundation

    /// The XDG base directories Skrepka writes into.
    ///
    /// Deliberately **not** `~/.skrepka`. The specification puts user data under
    /// `$XDG_DATA_HOME`, and a dotfile in `$HOME` is the thing it exists to stop:
    /// it survives no backup policy the user has configured, and it is invisible
    /// to every tool that knows where data belongs.
    ///
    /// Every path is derived from an injected environment rather than read from
    /// the process's, so the rules below are testable without a test mutating the
    /// environment of everything running beside it.
    public enum SessionPaths {
        /// The directory name under each base directory. Lowercase and
        /// unqualified, per the specification's convention for an application's
        /// own subdirectory.
        static let applicationDirectory = "skrepka"

        /// The history database. One file, plus whatever WAL sidecars SQLite keeps
        /// beside it.
        static let historyStoreName = "skrepka.sqlite3"

        /// `$XDG_DATA_HOME/skrepka`, or `~/.local/share/skrepka` when the variable
        /// is unset.
        ///
        /// An empty or relative `$XDG_DATA_HOME` is treated as unset, which the
        /// specification requires: "If an implementation encounters a relative path
        /// in any of these variables it should consider the path invalid and ignore
        /// it." Honouring a relative one would put the history wherever the daemon
        /// happened to be started from.
        public static func dataDirectory(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            base(
                environment[dataHomeVariable],
                fallback: homeDirectory.appending(path: ".local/share", directoryHint: .isDirectory)
            )
            .appending(path: applicationDirectory, directoryHint: .isDirectory)
        }

        /// The default location of the SQLite history database.
        public static func historyStoreURL(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            dataDirectory(environment: environment, homeDirectory: homeDirectory)
                .appending(path: historyStoreName, directoryHint: .notDirectory)
        }

        static let dataHomeVariable = "XDG_DATA_HOME"

        private static func base(_ value: String?, fallback: URL) -> URL {
            guard let value, value.hasPrefix("/") else { return fallback }
            return URL(filePath: value, directoryHint: .isDirectory)
        }
    }

#endif
