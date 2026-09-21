import Foundation
import SkrepkaSync

#if canImport(os)
    import os
#else
    import Logging
#endif

/// What a receiver may put on its clipboard for a file row another device
/// recorded. Pure: it decides, and the caller does the I/O it names.
///
/// **Never the foreign path.** A file copy's `public.file-url` is a path on the
/// machine that made the copy, and written here it pastes a reference to
/// nothing — or, worse, to whatever happens to live at that path on this
/// machine. So a foreign file row pastes as one of two things:
///
/// - its files, written locally by ``FileMaterializer`` from the bundle the
///   sender attached — plus the picture itself, when the one file is one; or
/// - the files' names as plain text, when no bundle came: a folder, a copy over
///   ``FileBundleReader/limit``, or a sender too old to attach one.
public enum ForeignFileGuard {
    public enum Decision: Sendable, Hashable {
        /// Not a file row from another device; write the payload as held.
        case passThrough
        /// Materialise these files, then write ``clipboard(forFilesAt:from:)``.
        case files(FileBundle)
        /// Write ``clipboard(forNames:)`` with this text.
        case names(String)
    }

    /// What to write, when `clipboard(…)` builds it: the payload, and the local
    /// files it names, for a platform whose clipboard takes a file list apart
    /// from the payload.
    public struct Clipboard: Sendable, Hashable {
        public let payload: ClipPayload
        public let fileURLs: [URL]
    }

    /// Decides for one row.
    ///
    /// - Parameters:
    ///   - representations: the bytes this device holds for the row, keyed by
    ///     local type.
    ///   - preview: the row's text, which names its files; the fallback when
    ///     the file URLs cannot be read for names.
    ///   - isForeign: whether another device recorded the row — its origin is
    ///     not this device.
    public static func decide(
        kind: ClipKind,
        representations: [String: Data],
        preview: String,
        isForeign: Bool
    ) -> Decision {
        guard isForeign, kind.isFileSystemEntry else { return .passThrough }
        if let bundle = bundle(in: representations), !bundle.files.isEmpty {
            return .files(bundle)
        }
        return .names(names(from: representations[PasteboardType.fileURL]) ?? preview)
    }

    /// The clipboard for materialised files: their local URLs — one as a URL,
    /// several as a `text/uri-list` — their names as text, and the picture's
    /// bytes when the bundle is a single picture.
    public static func clipboard(forFilesAt urls: [URL], from bundle: FileBundle) -> Clipboard {
        var representations: [String: Data] = [
            PasteboardType.fileURL: Data(urls.map(\.absoluteString).joined(separator: "\r\n").utf8),
            PasteboardType.string: Data(urls.map(\.lastPathComponent).joined(separator: "\n").utf8),
        ]
        if let picture = bundle.singleImage {
            representations[picture.type.storageType] = picture.bytes
        }
        return Clipboard(payload: ClipPayload(representations: representations), fileURLs: urls)
    }

    public static func clipboard(forNames text: String) -> Clipboard {
        Clipboard(
            payload: ClipPayload(representations: [PasteboardType.string: Data(text.utf8)]),
            fileURLs: []
        )
    }

    /// The picture a row's bundle holds, when it holds exactly one file and
    /// that file is a picture — what lets a synced image file show and paste
    /// as an image.
    public static func picture(in representations: [String: Data]) -> (type: ImageSignature, bytes: Data)? {
        bundle(in: representations)?.singleImage
    }

    /// The row's bundle, or nil when it has none or it will not decode — which
    /// is the same answer: a peer is authenticated, not trusted, and its bytes
    /// are its claim.
    private static func bundle(in representations: [String: Data]) -> FileBundle? {
        guard let encoded = representations[FileBundle.storageType] else { return nil }
        do {
            return try FileBundle(encoded: encoded)
        } catch {
            SkrepkaLog.sync.error("Ignored a file bundle that would not decode: \(String(describing: error))")
            return nil
        }
    }

    /// `representations` with the bundled picture's bytes added under their
    /// own type, for a thumbnail renderer that reads pictures by type. A type
    /// already held is left as it is.
    public static func withBundledPicture(_ representations: [String: Data]) -> [String: Data] {
        guard let picture = picture(in: representations) else { return representations }
        return representations.merging([picture.type.storageType: picture.bytes]) { held, _ in held }
    }

    /// The names in a file-URL representation, one per line — a Mac sends one
    /// URL, a Linux peer a `text/uri-list` of several — or nil when it names
    /// none.
    static func names(from fileURLData: Data?) -> String? {
        guard let fileURLData, let list = String(data: fileURLData, encoding: .utf8) else { return nil }
        let names =
            list
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { URL(string: $0)?.lastPathComponent }
            .filter { !$0.isEmpty && $0 != "/" }
        return names.isEmpty ? nil : names.joined(separator: "\n")
    }
}
