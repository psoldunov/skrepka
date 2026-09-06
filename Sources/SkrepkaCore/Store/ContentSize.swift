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
    /// deleted, or a selection too large to measure inside
    /// ``FileSelection/deadline``.
    ///
    /// - Parameter selection: what the file system said about every file the
    ///   entry names. Passed in rather than looked up here because
    ///   ``FileURLKind`` needs the same lookup and one is enough — see
    ///   ``CopiedSelection``.
    /// - Parameter deadline: the whole budget for measuring, spent across every
    ///   file rather than granted to each — see ``byteCount(of:deadline:)``.
    static func byteCount(
        of item: ClipItem,
        selection: CopiedSelection,
        deadline: Duration = FileSelection.deadline
    ) -> Int? {
        switch item.kind {
        case .file, .folder, .imageFile:
            return byteCount(of: selection, deadline: deadline)
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
    /// row that says nothing about size. A selection the stat walk could not
    /// finish stops for the same reason — see ``CopiedSelection/isComplete``.
    ///
    /// One budget for the whole sum, spent down rather than handed out afresh
    /// per file. Every folder in a selection is a directory walk of its own, so
    /// giving each one a full ``DirectorySize/deadline`` made the cost of a copy
    /// the number of folders in it — twenty folders is five seconds. This runs
    /// on ``ThumbnailRenderer``, which is serial and which
    /// ``HistoryStore/capture(_:)`` awaits before it stores anything, so that
    /// stall is not one late row: it is every copy made after it. What is left
    /// of the budget goes to the next file, and running out reports nil.
    ///
    /// So a copy of many folders usually reports no size at all. That is the
    /// intended answer rather than a shortfall — nil is already what a folder
    /// too large to measure shows — and it costs one line of a subtitle where
    /// the alternative costs the clipboard.
    static func byteCount(
        of selection: CopiedSelection,
        deadline: Duration = FileSelection.deadline
    ) -> Int? {
        guard selection.isComplete, !selection.files.isEmpty else { return nil }

        let clock = ContinuousClock()
        let start = clock.now
        var total = 0

        for file in selection.files {
            let remaining = deadline - (clock.now - start)
            guard remaining > .zero, let size = byteCount(of: file, deadline: remaining)
            else { return nil }
            total += size
        }
        return total
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
    ///
    /// - Parameter deadline: how long the directory walk may take. A plain file
    ///   ignores it — its size came off the one lookup ``CopiedFile`` already
    ///   made. Defaulted for a file measured on its own, and handed the
    ///   *remaining* budget by ``byteCount(of:deadline:)``, so a selection of
    ///   folders cannot spend a whole ``DirectorySize/deadline`` on each of
    ///   them.
    static func byteCount(of file: CopiedFile, deadline: Duration = DirectorySize.deadline) -> Int? {
        switch file.shape {
        case .folder, .package: DirectorySize.byteCount(ofDirectoryAt: file.url, deadline: deadline)
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
