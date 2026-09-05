import AppKit
import Foundation

/// Bundle identifier to display name, cached.
///
/// Resolving a bundle id hits the filesystem, and rows re-render on every
/// keystroke — without the cache that is a disk lookup per row per character.
@MainActor
final class AppNameCache {
    static let shared = AppNameCache()

    private var names: [String: String?] = [:]

    private init() {}

    func displayName(forBundleID bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        let resolved = Self.resolve(bundleID)
        names[bundleID] = resolved
        return resolved
    }

    private static func resolve(_ bundleID: String) -> String? {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
