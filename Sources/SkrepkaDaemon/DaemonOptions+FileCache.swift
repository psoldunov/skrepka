import Foundation
import SkrepkaCore

// MARK: - Where received files go

extension DaemonOptions {
    static let cacheHomeVariable = "XDG_CACHE_HOME"

    /// The root of the cache files received from peers are written under —
    /// see `SkrepkaCore.FileCache`, which adds `files/<contentHash>/` below it.
    ///
    /// `$XDG_CACHE_HOME/skrepka`, or `~/.cache/skrepka`: the files are rebuilt
    /// from the history database whenever a row is pasted, which is what the
    /// base directory specification's cache is for. Under `--data-dir` when one
    /// is given, so a test daemon on a temporary directory writes nothing into
    /// the developer's real cache. An empty or relative `$XDG_CACHE_HOME` is
    /// treated as unset, the rule `SessionPaths` applies to the other two.
    public func fileCacheRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let dataDirectory {
            return dataDirectory.appending(path: "cache", directoryHint: .isDirectory)
        }
        let base: URL
        if let value = environment[Self.cacheHomeVariable], value.hasPrefix("/") {
            base = URL(filePath: value, directoryHint: .isDirectory)
        } else {
            base = homeDirectory.appending(path: ".cache", directoryHint: .isDirectory)
        }
        return base.appending(path: "skrepka", directoryHint: .isDirectory)
    }
}
