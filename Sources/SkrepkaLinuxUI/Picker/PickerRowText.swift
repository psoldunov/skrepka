import Foundation
import SkrepkaCore
import SkrepkaIPC

/// The two strings a picker row shows: its title, and the subtitle beneath it.
///
/// A pure value so the assembly can be tested against exact strings. The row
/// widget in ``PickerRowView`` reads these and draws them; it decides nothing
/// about their contents.
public struct PickerRowText: Equatable, Sendable {
    /// The one-line preview, already flattened and masked by the daemon.
    public let title: String
    /// "Text · 3 lines · 10 seconds ago", built to mirror the macOS
    /// `ClipRowView` subtitle so the two platforms read the same.
    public let subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// Builds a ``PickerRowText`` from a ``ClipDocument``.
///
/// The subtitle rules are `Sources/SkrepkaCore/Models/ClipSummary.swift`'s,
/// transcribed rather than reused because a `ClipDocument` carries a flattened
/// preview and a separate line count where `ClipSummary` carries the original
/// text — so the line-count and size fields have to come straight off the
/// document. The order is the same as `ClipRowView.subtitle`:
/// type · image size · byte size · line count · age.
public enum PickerRowTextBuilder {
    /// - Parameter relativeAge: the age string, injected so the assembly is
    ///   testable without a clock or a locale — production passes
    ///   ``RelativeTime/string(from:to:)``.
    public static func make(
        _ document: ClipDocument,
        now: Date,
        relativeAge: (Date, Date) -> String = RelativeTime.string(from:to:)
    ) -> PickerRowText {
        var parts = [typeLabel(document)]
        if let size = imageSizeText(document) { parts.append(size) }
        if let size = byteSizeText(document) { parts.append(size) }
        if let lines = lineCountText(document) { parts.append(lines) }
        parts.append(relativeAge(document.createdAt, now))
        return PickerRowText(title: document.preview, subtitle: parts.joined(separator: " · "))
    }

    /// "Text", "Image", or "3 Files" for a copy of several.
    static func typeLabel(_ document: ClipDocument) -> String {
        let kind = ClipKind(rawValue: document.kind)
        if let kind, kind.isFileSystemEntry, (document.fileCount ?? 0) > 1 {
            return "\(document.fileCount ?? 0) \(kind.pluralDisplayName)"
        }
        return kind?.displayName ?? document.kind.capitalizedFirst
    }

    /// "1402 × 578", or nil when no single picture is being described.
    static func imageSizeText(_ document: ClipDocument) -> String? {
        guard !document.isConcealed, (document.fileCount ?? 0) <= 1,
            let width = document.imageWidth, let height = document.imageHeight
        else { return nil }
        return "\(width) × \(height)"
    }

    /// The content's size in decimal units, matching Finder, or nil.
    static func byteSizeText(_ document: ClipDocument) -> String? {
        guard !document.isConcealed, let bytes = document.byteCount else { return nil }
        return DecimalByteCount.string(bytes)
    }

    /// "3 lines" on a multi-line text row, or nil.
    static func lineCountText(_ document: ClipDocument) -> String? {
        let isFile = ClipKind(rawValue: document.kind)?.isFileSystemEntry ?? false
        guard !document.isConcealed, !isFile, let lines = document.lineCount, lines > 1 else {
            return nil
        }
        return "\(lines) lines"
    }
}

extension String {
    /// The string with its first character upper-cased — for a `kind` this
    /// build has no `ClipKind` for, so an unknown kind still lists rather than
    /// shows a bare lowercase word.
    fileprivate var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
