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
    static func byteCount(of item: ClipItem) -> Int? {
        switch item.kind {
        case .file, .folder, .imageFile:
            return byteCount(ofFilesAt: item.fileURLs)
        case .image:
            return imageByteCount(in: item.payload)
        case .text, .richText, .link:
            return nil
        }
    }

    /// What a whole copied selection weighs, or nil when any part of it cannot
    /// be measured.
    ///
    /// All or nothing on purpose, and for the reason ``DirectorySize`` gives:
    /// the sum of two files out of three is a wrong number that looks like a
    /// right one, and a row reading "1.2 MB" for a copy of 4 GB is worse than a
    /// row that says nothing about size. A selection too long to finish inside
    /// ``FileSelection/deadline`` stops for the same reason.
    static func byteCount(ofFilesAt urls: [URL], deadline: Duration = FileSelection.deadline) -> Int? {
        guard !urls.isEmpty else { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        var total = 0

        for url in urls {
            if clock.now - start > deadline { return nil }
            guard let size = byteCount(ofFileAt: url) else { return nil }
            total += size
        }
        return total
    }

    /// The file's own size, or the sum of a directory's contents.
    ///
    /// A package takes the directory path: `ChatGPT.app` classifies as a file
    /// — see ``FileURLKind`` — but its size is still everything inside it,
    /// which is the number Finder reports for it too.
    static func byteCount(ofFileAt url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        else { return nil }
        guard values.isDirectory == true else { return values.fileSize }
        return DirectorySize.byteCount(ofDirectoryAt: url)
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
