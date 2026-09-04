import AppKit
import Foundation

/// The thin AppKit shim between `NSPasteboard` and the pure capture rules.
///
/// `NSPasteboard` carries no `NS_SWIFT_UI_ACTOR` annotation in the macOS 26 SDK
/// (verified against `NSPasteboard.h`), so reading it off the main actor is
/// sanctioned rather than merely tolerated.
public struct PasteboardReader: Sendable {
    /// Types Clippy pulls data for. Reading every declared type would drag in
    /// megabytes of private app formats for no benefit.
    static let interestingTypes: Set<String> = Set(PasteboardType.readOrder)

    public init() {}

    /// Current change counter. Cheap — a single IPC round-trip.
    public func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Freezes the general pasteboard into a value, or nil when it is empty.
    public func snapshot(sourceBundleID: String?) -> PasteboardSnapshot? {
        let pasteboard = NSPasteboard.general
        guard let item = pasteboard.pasteboardItems?.first else { return nil }

        let declaredTypes = item.types.map(\.rawValue)
        // Check the markers before reading a single byte of content.
        guard !PrivacyMarkers.isRejected(types: declaredTypes) else {
            return PasteboardSnapshot(
                representations: [:],
                declaredTypes: declaredTypes,
                sourceBundleID: sourceBundleID
            )
        }

        var representations: [String: Data] = [:]
        for type in item.types where Self.interestingTypes.contains(type.rawValue) {
            guard let data = item.data(forType: type), !data.isEmpty else { continue }
            representations[type.rawValue] = data
        }

        return PasteboardSnapshot(
            representations: representations,
            declaredTypes: declaredTypes,
            sourceBundleID: sourceBundleID
        )
    }
}
