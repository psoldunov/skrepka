import Foundation
import Logging

#if canImport(Glibc)
    import Glibc
#endif

/// `config.json` on the disk: read once at start, rewritten whole on every
/// change.
///
/// **The daemon never refuses to start over this file.** A missing file is the
/// defaults, which are what the daemon did before the file existed. A file that
/// will not parse, or holds a value no client could have set, is moved aside to
/// `config.json.bad` — kept, because it is the user's, and out of the way,
/// because the next save would otherwise overwrite the evidence — logged, and
/// replaced by the defaults. A clipboard manager that would not start because
/// of a stray comma in a hand edit is worse than one that forgot a setting.
struct DaemonSettingsFile: Sendable {
    /// How a read went, beside what it produced — for the log, and for tests.
    enum Outcome: Sendable, Equatable {
        case absent
        case loaded
        /// The file was unusable and has been moved to ``quarantineURL``.
        case quarantined(reason: String)
    }

    enum SaveError: Error, Sendable, CustomStringConvertible {
        case cannotReplace(path: String, reason: String)

        var description: String {
            switch self {
            case .cannotReplace(let path, let reason): "could not write \(path): \(reason)"
            }
        }
    }

    let url: URL

    /// Where an unusable file is moved to.
    var quarantineURL: URL {
        url.deletingLastPathComponent().appending(
            path: url.lastPathComponent + ".bad", directoryHint: .notDirectory)
    }

    /// The settings to run with, logging anything worth knowing about the
    /// file they came from.
    func load(logger: Logger) -> DaemonSettings {
        let (settings, outcome) = read()
        switch outcome {
        case .absent:
            logger.info("no settings file; using the defaults", metadata: ["path": .string(url.path)])
        case .loaded:
            logger.info("read settings", metadata: ["path": .string(url.path)])
        case .quarantined(let reason):
            logger.warning(
                "the settings file was unusable; moved it aside and using the defaults",
                metadata: [
                    "path": .string(url.path),
                    "movedTo": .string(quarantineURL.path),
                    "reason": .string(reason),
                ])
        }
        return settings
    }

    func read() -> (DaemonSettings, Outcome) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (.default, .absent) }
        let reason: String
        do {
            let settings = try JSONDecoder().decode(DaemonSettings.self, from: Data(contentsOf: url))
            guard let problem = settings.problem else { return (settings, .loaded) }
            reason = problem
        } catch {
            reason = String(describing: error)
        }
        let moved = rename(url.path, quarantineURL.path) == 0
        let suffix = moved ? "" : " (and it could not be moved aside: \(Self.lastError()))"
        return (.default, .quarantined(reason: reason + suffix))
    }

    /// Writes `settings` so that a reader sees the old file or the new one and
    /// never half of either: a temporary file beside it, then `rename(2)` over
    /// it, which replaces the destination in one step on the same filesystem.
    func save(_ settings: DaemonSettings) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.append(0x0A)

        let temporary = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            let reason = Self.lastError()
            // Best effort: the temporary file is ours and useless now, and the
            // failure being reported is the rename, not this.
            try? FileManager.default.removeItem(at: temporary)
            throw SaveError.cannotReplace(path: url.path, reason: reason)
        }
    }

    private static func lastError() -> String {
        String(cString: strerror(errno))
    }
}
