import AppKit
import Foundation

/// The thin AppKit shim between `NSPasteboard` and the pure capture rules.
///
/// `NSPasteboard` carries no `NS_SWIFT_UI_ACTOR` annotation in the macOS 26 SDK
/// (verified against `NSPasteboard.h`), so reading it off the main actor is
/// sanctioned rather than merely tolerated.
public struct PasteboardReader: Sendable {
    /// Types Skrepka pulls data for. Reading every declared type would drag in
    /// megabytes of private app formats for no benefit.
    static let interestingTypes: Set<String> = Set(PasteboardType.readOrder)

    public init() {}

    /// Current change counter. Cheap — a single IPC round-trip.
    public func changeCount() -> Int {
        NSPasteboard.general.changeCount
    }

    /// Freezes the general pasteboard into a value.
    ///
    /// Returns ``PasteboardRead/unreadable`` rather than an empty snapshot when
    /// the pasteboard yields no item at all, so a denied read is reportable
    /// instead of silent.
    public func read(sourceBundleID: String?) -> PasteboardRead {
        let pasteboard = NSPasteboard.general
        let items = pasteboard.pasteboardItems ?? []
        guard let item = items.first else { return .unreadable }

        let declaredTypes = item.types.map(\.rawValue)
        // Check the markers before reading a single byte of content.
        guard !PrivacyMarkers.isRejected(types: declaredTypes) else {
            return .contents(
                PasteboardSnapshot(
                    representations: [:],
                    declaredTypes: declaredTypes,
                    sourceBundleID: sourceBundleID
                )
            )
        }

        var representations: [String: Data] = [:]
        for type in item.types where Self.interestingTypes.contains(type.rawValue) {
            guard let data = item.data(forType: type), !data.isEmpty else { continue }
            representations[type.rawValue] = data
        }

        return .contents(
            PasteboardSnapshot(
                representations: representations,
                declaredTypes: declaredTypes,
                fileURLs: Self.fileURLs(in: items),
                sourceBundleID: sourceBundleID
            )
        )
    }

    /// The file URL every item on the pasteboard points at.
    ///
    /// Reading past the first item is what makes a copy of several files one
    /// entry that knows it holds several — the first item is the only one the
    /// payload keeps. One string per item and no bytes off disk, so the poller's
    /// tick pays a cheap IPC round trip per file rather than a read.
    ///
    /// Items carrying no file URL are skipped rather than counted, so a copy
    /// that mixes a file with something else does not claim a file it has not
    /// got. A URL string that will not parse as a file URL is skipped for the
    /// same reason — any app may put anything under that type.
    static func fileURLs(in items: [NSPasteboardItem]) -> [URL] {
        let fileURLType = NSPasteboard.PasteboardType(PasteboardType.fileURL)
        return items.compactMap { item in
            guard let string = item.string(forType: fileURLType),
                let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    /// The system's current policy for programmatic reads of the general
    /// pasteboard. Reading the policy does not itself count as an access.
    public func accessBehavior() -> PasteboardAccess {
        PasteboardAccess(NSPasteboard.general.accessBehavior)
    }

    /// Writes a marker and reads it straight back, which is what provokes the
    /// system's pasteboard access alert on a first run.
    ///
    /// - Returns: true when the marker came back intact — direct proof that
    ///   programmatic reads are allowed. The policy cannot answer this: an
    ///   "Allow Once" leaves `accessBehavior` reporting `.ask`.
    ///
    /// The round trip is Skrepka's own content, so nothing of the user's is
    /// touched to provoke the prompt. Callers must pause the poller around it;
    /// otherwise the marker is captured as a history entry.
    public func probeAccess() -> Bool {
        let marker = "Skrepka is ready"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)
        return pasteboard.pasteboardItems?.first?.string(forType: .string) == marker
    }
}
