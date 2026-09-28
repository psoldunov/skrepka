import Foundation
import SkrepkaCore

/// `app.json` on the disk: ``AppPreferences``, read when the app starts and
/// rewritten whole when a setting in it changes.
///
/// Never a reason not to start. A missing file is the defaults; one that will
/// not parse is the defaults too, with a line in the log, and is replaced the
/// next time a setting changes — it holds nothing a user would have to
/// recreate by hand.
///
/// Read and written on the main loop's thread, synchronously, as
/// ``AutostartEntry`` is: one small file in the user's own config directory.
struct AppPreferencesFile {
    static let fileName = "app.json"

    let url: URL

    /// `$XDG_CONFIG_HOME/skrepka/app.json`, beside the daemon's `config.json`.
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        AppPreferencesFile(
            url: SessionPaths.configDirectory(environment: environment)
                .appending(path: fileName, directoryHint: .notDirectory))
    }

    /// The preferences to run with.
    func load() -> AppPreferences {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: Data(contentsOf: url))
        } catch {
            AppLog.note("could not read \(url.path), using the defaults: \(error)")
            return .default
        }
    }

    /// Writes `preferences`, replacing the file in one step. Answers a
    /// sentence for the user when it could not, and nil when it did.
    func save(_ preferences: AppPreferences) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var data = try encoder.encode(preferences)
            data.append(0x0A)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            AppLog.note("could not write \(url.path): \(error)")
            let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            return "Skrepka could not save this to \(path): \(error.localizedDescription)"
        }
    }
}
