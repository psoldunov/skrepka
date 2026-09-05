import Foundation

/// How large the copied thing is, for the row subtitle.
///
/// Two different questions wear one label. A copied *file* is a path, and its
/// size is the file system's answer about something Skrepka never held. A
/// copied *image* is bytes that arrived on the pasteboard, and its size is
/// those bytes. Kinds that carry their own text — a sentence, a link — get no
/// size at all: the row already says how many lines it is, and "18 bytes" tells
/// nobody anything.
enum ContentSize {
    /// Bytes to show for the entry, or nil when there is no honest answer:
    /// a kind with no size worth showing, a file that has moved or been
    /// deleted, or a folder too large to measure inside
    /// ``DirectorySize/deadline``.
    ///
    /// - Parameter file: what the file system said about the copied path, or
    ///   nil when the entry names no file or the file system would not answer.
    ///   Passed in rather than looked up here because ``FileURLKind`` needs the
    ///   same lookup and one is enough — see ``CopiedFile``.
    static func byteCount(of item: ClipItem, file: CopiedFile?) -> Int? {
        switch item.kind {
        case .file, .folder:
            guard let file else { return nil }
            return byteCount(of: file)
        case .image:
            return imageByteCount(in: item.payload)
        case .text, .richText, .link:
            return nil
        }
    }

    /// The file's own size, or the sum of a directory's contents.
    ///
    /// A package takes the directory path: `ChatGPT.app` classifies as a file
    /// — see ``FileURLKind`` — but its size is still everything inside it,
    /// which is the number Finder reports for it too.
    ///
    /// ``CopiedFile/Shape/unknown`` takes the file branch and reports
    /// ``CopiedFile/fileSize``, which is nil in that situation anyway.
    /// ``FileURLKind`` refuses to answer at all on the same input, and both are
    /// right: a wrong *kind* is a mislabelled row that outlives the copy, where
    /// a missing *size* is one line the subtitle leaves off.
    static func byteCount(of file: CopiedFile) -> Int? {
        switch file.shape {
        case .folder, .package: DirectorySize.byteCount(ofDirectoryAt: file.url)
        case .file, .unknown: file.fileSize
        }
    }

    /// Size of the richest image representation on the pasteboard.
    ///
    /// The same ranking ``ThumbnailMaker`` previews from, so the number
    /// describes the bytes the row is showing a picture of. Summing every
    /// representation instead would report a PNG and the TIFF beside it as one
    /// picture of twice the size.
    private static func imageByteCount(in payload: ClipPayload) -> Int? {
        let imageTypes = [PasteboardType.png, PasteboardType.tiff, PasteboardType.pdf]
        for type in imageTypes {
            if let data = payload.data(forType: type) { return data.count }
        }
        return nil
    }
}
