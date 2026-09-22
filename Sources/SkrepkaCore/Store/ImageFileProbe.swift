import Foundation
import SkrepkaSync

#if canImport(os)
    import os
#else
    import Logging
#endif

/// Tells a copied picture from any other copied file without decoding it, and
/// reads the picture back when a row is drawn.
///
/// The Linux counterpart of `ImageFileThumbnail`, divided differently. The Mac
/// decodes once, at copy time, and stores the thumbnail it made. The Linux
/// daemon links no image decoder, so at copy time it records only what the
/// file's header says — that it is a picture, and its size — and the picture
/// itself is read when `skrepka-gui` asks to draw the row, which decodes it on
/// GdkPixbuf there and then. Portable, so its tests run on both platforms, but
/// only the Linux daemon and store call it.
///
/// One file only. A selection of three pictures stays three Files, as a synced
/// one already did: the picker draws one picture per row, and a stack of them
/// is the Mac's `FileIconStack`, which Linux does not have.
public enum ImageFileProbe {
    /// A bundle's one file, and what its header says.
    public typealias BundledPicture = (header: PictureHeader, bytes: Data)

    /// What reading a row's picture came to.
    public enum Outcome: Sendable, Hashable {
        case picture(PictureFormat, Data)
        /// Larger than the limit asked for, by its size or by what was read.
        case tooLarge
        /// Gone, unreadable, not a regular file, or not a picture after all.
        case unavailable
    }

    /// `item` as an image file, sized from its picture's header, when it is a
    /// copy of exactly one file and that file is a picture — else `item` as it
    /// was.
    ///
    /// The evidence is the bundle ``FileBundleReader`` attached when there is
    /// one — the file as it was at the copy, already in memory — and the head
    /// of the file on disk only when there is not. A bundle whose file is not
    /// a picture settles it; the disk is not asked a second time.
    ///
    /// `contentHash` is kept rather than recomputed. The Mac hashes a copy as
    /// the `.file` its capture rules call it and relabels the row afterwards,
    /// and peers know an entry by that hash, so it has to come out the same
    /// here whatever the row ends up called.
    ///
    /// Blocking reads, run off the caller's actor like
    /// ``FileBundleReader/attachingBundle(to:limit:)``, whose result this is
    /// meant to be handed.
    @concurrent
    public static func refining(_ item: ClipItem) async -> ClipItem {
        guard item.kind == .file, !item.isConcealed, item.fileURLs.count == 1,
            let url = item.fileURLs.first, url.isFileURL
        else { return item }
        let header: PictureHeader?
        if let bundle = bundle(in: item.payload.representations) {
            header = bundle.files.count == 1 ? bundle.files.first.flatMap { PictureHeader($0.bytes) } : nil
        } else {
            header = OpenedFile.head(url.resolvingSymlinksInPath(), length: PictureHeader.length)
                .flatMap(PictureHeader.init)
        }
        guard let header else { return item }
        return ClipItem(
            id: item.id,
            kind: .imageFile,
            text: item.text,
            payload: item.payload,
            sourceBundleID: item.sourceBundleID,
            createdAt: item.createdAt,
            isPinned: item.isPinned,
            isConcealed: item.isConcealed,
            imageSize: header.displaySize ?? item.imageSize,
            fileURLs: item.fileURLs,
            contentHash: item.contentHash
        )
    }

    /// The one file a row's bundle holds, with what its header says, when that
    /// file is a picture.
    ///
    /// Any format ``PictureFormat`` knows, not only the three a clipboard can
    /// carry — which is where this differs from
    /// ``ForeignFileGuard/picture(in:)``, the rule for what *pastes* as a
    /// picture.
    public static func bundledPicture(in representations: [String: Data]) -> BundledPicture? {
        guard let bundle = bundle(in: representations), bundle.files.count == 1,
            let bytes = bundle.files.first?.bytes, let header = PictureHeader(bytes)
        else { return nil }
        return (header, bytes)
    }

    /// The picture at `url`, read whole when it is no larger than `limit` bytes.
    ///
    /// For a row copied on this device with no bundle to draw from — file
    /// sync switched off, or the file over its limit. Read when the row is
    /// drawn, not when it was copied, so a file edited since shows as it is
    /// now; a bundle, where there is one, is the copy as it was.
    ///
    /// Never call it with a path from another device's row. That path names
    /// something on the other machine, and whatever this one keeps there is
    /// not the picture that was copied.
    @concurrent
    public static func picture(atFileURL url: URL, limit: Int) async -> Outcome {
        guard url.isFileURL else { return .unavailable }
        switch OpenedFile.read(url.resolvingSymlinksInPath(), atMost: limit) {
        case .bytes(let bytes):
            guard let format = PictureFormat(sniffing: bytes) else { return .unavailable }
            return .picture(format, bytes)
        case .tooLarge:
            return .tooLarge
        case .notARegularFile:
            return .unavailable
        }
    }

    /// The row's bundle, or nil when it has none or it will not decode — the
    /// same answer here, since either way there is no file in it to judge.
    private static func bundle(in representations: [String: Data]) -> FileBundle? {
        guard let encoded = representations[FileBundle.storageType] else { return nil }
        do {
            return try FileBundle(encoded: encoded)
        } catch {
            SkrepkaLog.store.error(
                "Ignored a file bundle that would not decode: \(String(describing: error))")
            return nil
        }
    }
}
