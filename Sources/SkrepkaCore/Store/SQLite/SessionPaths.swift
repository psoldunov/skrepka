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

        /// The device's sync identity — its private key and certificate.
        ///
        /// Under `$XDG_DATA_HOME` rather than `$XDG_CONFIG_HOME`, and that is
        /// the specification's own line rather than a preference: config is
        /// what a user edits, and this is generated, opaque and unique to the
        /// installation. It is also the one file here that must be created with
        /// mode `0600` rather than `chmod`-ed into it afterwards — `TrustStore`
        /// says so, and the window between creating a world-readable file and
        /// tightening it is small and real.
        ///
        /// Deleting it un-pairs this device from every peer, because
        /// `SyncDeviceID` is the hash of certificate bytes that would no longer
        /// exist.
        public static func deviceKeyURL(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            dataDirectory(environment: environment, homeDirectory: homeDirectory)
                .appending(path: deviceKeyName, directoryHint: .notDirectory)
        }

        /// `$XDG_CONFIG_HOME/skrepka`, or `~/.config/skrepka` when unset.
        ///
        /// Where the settings a user may edit by hand live — the retention
        /// policy, the exclusion list, whether sync is on. Separate from the
        /// data directory because the specification separates them and because
        /// the two want different backup treatment: config is worth keeping,
        /// a clipboard history mostly is not.
        public static func configDirectory(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            base(
                environment[configHomeVariable],
                fallback: homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
            )
            .appending(path: applicationDirectory, directoryHint: .isDirectory)
        }

        /// The daemon's settings file.
        public static func configURL(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        ) -> URL {
            configDirectory(environment: environment, homeDirectory: homeDirectory)
                .appending(path: configName, directoryHint: .notDirectory)
        }

        static let deviceKeyName = "device.key"
        static let configName = "config.json"
        static let dataHomeVariable = "XDG_DATA_HOME"
        static let configHomeVariable = "XDG_CONFIG_HOME"

        private static func base(_ value: String?, fallback: URL) -> URL {
            guard let value, value.hasPrefix("/") else { return fallback }
            return URL(filePath: value, directoryHint: .isDirectory)
        }
    }

#endif
