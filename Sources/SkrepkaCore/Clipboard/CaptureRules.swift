import Foundation

/// Turns a ``PasteboardSnapshot`` into a ``CaptureDecision``.
///
/// Pure and synchronous: no pasteboard, no clock, no storage, no file system.
/// This is where the privacy rules live, so they are covered by tests rather
/// than by hope.
///
/// Purity is load-bearing rather than tidy. This runs inside
/// ``ClipboardWatcher/checkForChange()``, which writes the change count down
/// before it reads, so anything that blocks here costs history: copies made
/// during the stall are never seen, and when the watcher wakes it captures only
/// whatever is on the clipboard by then. A `public.file-url` under an
/// unresponsive mount is exactly such a stall, which is why telling a copied
/// folder from a copied file — see ``FileURLKind`` — happens later, on
/// ``ThumbnailRenderer``, alongside the other work that has to open the copied
/// thing.
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

        let fileURLs = kind.isFileSystemEntry ? Self.fileURLs(in: snapshot, payload: payload) : []
        let text = Self.text(for: kind, payload: payload, fileURLs: fileURLs)
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
                isConcealed: PrivacyMarkers.isConcealed(types: snapshot.declaredTypes),
                fileURLs: fileURLs
            )
        )
    }

    /// The files the copy holds, with the payload's own file leading.
    ///
    /// The snapshot lists them in pasteboard order and the payload holds the
    /// first item's, so the two normally agree. Normally is not always: an app
    /// may put a file URL under a type the reader took no other item from, and
    /// an entry whose first file disagreed with its payload would paste one file
    /// and measure another. Leading with the payload's own settles that, and
    /// duplicates are dropped so the leader is not counted twice.
    static func fileURLs(in snapshot: PasteboardSnapshot, payload: ClipPayload) -> [URL] {
        var ordered = snapshot.fileURLs
        if let first = payload.fileURL {
            ordered = [first] + ordered.filter { $0 != first }
        }
        var seen: Set<URL> = []
        return ordered.filter { seen.insert($0).inserted }
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
    ///
    /// A `public.file-url` reads as ``ClipKind/file`` whatever is at the end of
    /// it. Only the file system can say whether that is a folder, and asking it
    /// from here would put a blocking disk call in the watcher's look;
    /// ``ThumbnailRenderer`` refines the kind instead.
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
    ///
    /// A file entry is named by the files it actually holds, one per line, so
    /// the row lists what the row can paste. The pasteboard's own text flavour
    /// is not that list: Finder writes the *display* names of the whole
    /// selection there, which hides extensions when the user has asked it to and
    /// keeps naming files that arrived without their URL — a copy relayed
    /// through Universal Clipboard names three pictures and hands over one.
    ///
    /// Only the first ``FileSelection/maximumNamedFiles`` of them, because this
    /// string is stored, searched and re-joined on every draw — see the constant
    /// for what that costs and what it gives up. The files are not capped with
    /// the names: the row still holds and pastes every one of them.
    static func text(for kind: ClipKind, payload: ClipPayload, fileURLs: [URL]) -> String {
        if kind.isFileSystemEntry, !fileURLs.isEmpty {
            return fileURLs.prefix(FileSelection.maximumNamedFiles)
                .map(Self.displayName(ofFileAt:))
                .joined(separator: "\n")
        }
        let textTypes = [PasteboardType.string, PasteboardType.url, PasteboardType.fileURL]
        for type in textTypes {
            guard let data = payload.data(forType: type),
                let string = String(data: data, encoding: .utf8)
            else { continue }
            return kind.isFileSystemEntry ? Self.displayPath(forFileURL: string) : string
        }
        return ""
    }

    /// `file:///Users/me/Pictures/shot.png` reads as `shot.png`. Percent
    /// escapes are already decoded by `lastPathComponent`, so a name with a
    /// space in it arrives spelled the way Finder spells it.
    static func displayName(ofFileAt url: URL) -> String {
        url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    /// The same, for a file named by a string rather than by a URL — which is
    /// what is left when the pasteboard carried no file URL to read.
    static func displayPath(forFileURL string: String) -> String {
        guard let url = URL(string: string), url.isFileURL else { return string }
        return displayName(ofFileAt: url)
    }
}
