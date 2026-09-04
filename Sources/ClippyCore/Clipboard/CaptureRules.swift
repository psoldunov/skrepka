import Foundation

/// Turns a ``PasteboardSnapshot`` into a ``CaptureDecision``.
///
/// Pure and synchronous: no pasteboard, no clock, no storage. This is where the
/// privacy rules live, so they are covered by tests rather than by hope.
public struct CaptureRules: Sendable {
    /// Per-item ceiling. Above this the entry is dropped rather than stored;
    /// a 200 MB screenshot is not history, it is a memory leak.
    public let maximumItemBytes: Int
    /// Bundle identifiers the user never wants recorded.
    public let excludedBundleIDs: Set<String>

    public init(maximumItemBytes: Int = 32 * 1024 * 1024, excludedBundleIDs: Set<String> = []) {
        self.maximumItemBytes = maximumItemBytes
        self.excludedBundleIDs = excludedBundleIDs
    }

    public func decide(_ snapshot: PasteboardSnapshot) -> CaptureDecision {
        if PrivacyMarkers.isRejected(types: snapshot.declaredTypes) {
            return .rejectedPrivacyMarker
        }
        if let bundleID = snapshot.sourceBundleID, excludedBundleIDs.contains(bundleID) {
            return .rejectedExcludedApp(bundleID: bundleID)
        }

        let payload = ClipPayload(representations: snapshot.representations.filter { !$0.value.isEmpty })
        guard !payload.isEmpty, let kind = Self.kind(for: payload) else {
            return .rejectedEmpty
        }
        guard payload.byteCount <= maximumItemBytes else {
            return .rejectedTooLarge(byteCount: payload.byteCount)
        }

        let text = Self.text(for: kind, payload: payload)
        guard kind == .image || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejectedEmpty
        }

        return .captured(
            ClipItem(
                kind: kind,
                text: text,
                payload: payload,
                sourceBundleID: snapshot.sourceBundleID,
                createdAt: snapshot.capturedAt,
                isConcealed: PrivacyMarkers.isConcealed(types: snapshot.declaredTypes)
            )
        )
    }

    /// Richest representation wins, per ``PasteboardType/readOrder``.
    static func kind(for payload: ClipPayload) -> ClipKind? {
        for type in PasteboardType.readOrder where payload.data(forType: type) != nil {
            switch type {
            case PasteboardType.rtfd, PasteboardType.rtf, PasteboardType.html: return .richText
            case PasteboardType.fileURL: return .file
            case PasteboardType.url: return .link
            case PasteboardType.png, PasteboardType.tiff, PasteboardType.pdf: return .image
            case PasteboardType.string: return .text
            default: continue
            }
        }
        return nil
    }

    /// Plain-text rendering used for search, row labels and plain paste.
    ///
    /// Images legitimately have none; the picker labels those from their kind
    /// and dimensions instead.
    static func text(for kind: ClipKind, payload: ClipPayload) -> String {
        let textTypes = [PasteboardType.string, PasteboardType.url, PasteboardType.fileURL]
        for type in textTypes {
            guard let data = payload.data(forType: type),
                let string = String(data: data, encoding: .utf8)
            else { continue }
            return kind == .file ? Self.displayPath(forFileURL: string) : string
        }
        return ""
    }

    /// `file:///Users/me/Pictures/shot.png` reads better as `shot.png`.
    static func displayPath(forFileURL string: String) -> String {
        guard let url = URL(string: string), url.isFileURL else { return string }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }
}
