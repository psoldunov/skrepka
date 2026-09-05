import Foundation

/// Turns a ``PasteboardSnapshot`` into a ``CaptureDecision``.
///
/// Pure and synchronous: no pasteboard, no clock, no storage. This is where the
/// privacy rules live, so they are covered by tests rather than by hope.
public struct CaptureRules: Sendable {
    /// The default per-item ceiling, named rather than spelled inline so the
    /// sync target can be checked against it.
    ///
    /// `SkrepkaSync` restates this number as `SyncLimits.maximumPayloadBytes` —
    /// it cannot import `SkrepkaCore`, which does not build on Linux — and
    /// `SyncLimitsTests` fails if the two ever drift. An item too large to
    /// capture is too large to receive, and two limits that can disagree is one
    /// limit and one bug.
    public static let defaultMaximumItemBytes = 32 * 1024 * 1024

    /// Per-item ceiling. Above this the entry is dropped rather than stored;
    /// a 200 MB screenshot is not history, it is a memory leak.
    public let maximumItemBytes: Int
    /// Bundle identifiers the user never wants recorded.
    public let excludedBundleIDs: Set<String>

    public init(
        maximumItemBytes: Int = CaptureRules.defaultMaximumItemBytes,
        excludedBundleIDs: Set<String> = []
    ) {
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
            return Self.emptyReason(declaredTypes: snapshot.declaredTypes)
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

    /// Tells "the clipboard holds nothing we want" apart from "we were not
    /// allowed to read what it holds".
    ///
    /// Reached only once every representation has come back empty, so the
    /// question left is narrow: did the item advertise a type Skrepka reads? If
    /// it did and yielded no bytes, something refused the read — macOS gates
    /// programmatic access to the general pasteboard, so on a machine where the
    /// user has denied Skrepka this is every single copy, and reporting it as
    /// "empty" is what made the failure invisible.
    ///
    /// Takes the declared types rather than the whole snapshot: the
    /// representations cannot inform this answer, because reaching here is
    /// what proves they are all empty.
    static func emptyReason(declaredTypes: [String]) -> CaptureDecision {
        let readable = Set(PasteboardType.readOrder)
        return declaredTypes.contains(where: readable.contains) ? .rejectedUnreadable : .rejectedEmpty
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
