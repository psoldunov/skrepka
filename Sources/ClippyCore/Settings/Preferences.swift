import Foundation
import Observation

/// User-visible settings, backed by `UserDefaults`.
///
/// Observation-based so SwiftUI tracks reads in `body` directly; writes go
/// straight through to defaults, which is what makes them survive a relaunch.
@MainActor
@Observable
public final class Preferences {
    /// "No limit", stored rather than represented by an absent key — removing
    /// the key would read back as the default on the next launch, silently
    /// undoing the user's choice.
    private static let noLimit = 0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        maximumItems = Self.limit(defaults.value(for: .maximumItems))
        maximumAgeDays = Self.limit(defaults.value(for: .maximumAgeDays))
        excludedBundleIDs = Set(defaults.value(for: .excludedBundleIDs))
        launchAtLogin = defaults.value(for: .launchAtLogin)
        pasteAutomatically = defaults.value(for: .pasteAutomatically)
    }

    /// Maximum unpinned entries, nil for unlimited.
    public var maximumItems: Int? {
        didSet { defaults.set(maximumItems ?? Self.noLimit, for: .maximumItems) }
    }

    /// Maximum age of an unpinned entry in days, nil for unlimited.
    public var maximumAgeDays: Int? {
        didSet { defaults.set(maximumAgeDays ?? Self.noLimit, for: .maximumAgeDays) }
    }

    /// Apps whose copies are never recorded. Backstop for password managers
    /// that do not set the `org.nspasteboard.*` markers.
    public var excludedBundleIDs: Set<String> {
        didSet { defaults.set(Array(excludedBundleIDs).sorted(), for: .excludedBundleIDs) }
    }

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, for: .launchAtLogin) }
    }

    /// When off, selecting an entry only puts it on the pasteboard and the user
    /// pastes themselves — which needs no Accessibility permission.
    public var pasteAutomatically: Bool {
        didSet { defaults.set(pasteAutomatically, for: .pasteAutomatically) }
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maximumItems: maximumItems,
            maximumAge: maximumAgeDays.map { TimeInterval($0) * 60 * 60 * 24 }
        )
    }

    public var captureRules: CaptureRules {
        CaptureRules(excludedBundleIDs: excludedBundleIDs)
    }

    private static func limit(_ stored: Int) -> Int? {
        stored <= noLimit ? nil : stored
    }
}

/// A typed defaults key and the value to use when nothing is stored.
///
/// Carrying the default here means a typo is a compile error rather than a
/// setting that silently never persists, and no call site repeats `?? default`.
struct PreferenceKey<Value: Sendable>: Sendable {
    let name: String
    let defaultValue: Value

    static var maximumItems: PreferenceKey<Int> {
        .init(name: "maximumItems", defaultValue: RetentionPolicy.default.maximumItems ?? 0)
    }
    static var maximumAgeDays: PreferenceKey<Int> {
        .init(name: "maximumAgeDays", defaultValue: 30)
    }
    static var excludedBundleIDs: PreferenceKey<[String]> {
        .init(name: "excludedBundleIDs", defaultValue: [])
    }
    static var launchAtLogin: PreferenceKey<Bool> {
        .init(name: "launchAtLogin", defaultValue: false)
    }
    static var pasteAutomatically: PreferenceKey<Bool> {
        .init(name: "pasteAutomatically", defaultValue: true)
    }
}

extension UserDefaults {
    func value<Value>(for key: PreferenceKey<Value>) -> Value {
        object(forKey: key.name) as? Value ?? key.defaultValue
    }

    func set<Value>(_ value: Value, for key: PreferenceKey<Value>) {
        set(value, forKey: key.name)
    }
}
