import Foundation

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

/// One look at the thing a `public.file-url` points at.
///
/// Exists because two separate questions are asked about every copied file and
/// the answer to both comes from the same syscall. ``FileURLKind`` wants to know
/// whether it is a directory and whether that directory is a package;
/// ``ContentSize`` wants to know whether it is a directory and how large it is.
/// Asked independently that is two `resourceValues` round trips per capture,
/// with `.isDirectoryKey` fetched twice — and separate `URL` instances share no
/// CFURL resource cache, so nothing collapses them.
///
/// On a local disk the second trip is microseconds. It matters on the case the
/// whole detail pass is arranged around: a path under a mount that has stopped
/// responding, where each lookup blocks until the mount times out and asking
/// twice doubles a stall the user is waiting through. ``ThumbnailRenderer``
/// makes one of these and hands it to both.
///
/// A value rather than a cached lookup on `URL`: it crosses no isolation
/// boundary today, but it is `Sendable` for free and it is the shape that says
/// "this is what the file system said, once, at capture time" — which is what
/// every reader of it needs to know.
struct CopiedFile: Sendable, Hashable {
    /// What the file system said is at the end of the URL.
    ///
    /// Four cases rather than two booleans, because the two readers do not
    /// partition them the same way and a `Bool` pair invites reading one
    /// without the other. ``FileURLKind`` groups ``package`` with ``file``, so
    /// a copied `.app` keeps a document icon and its preview; ``ContentSize``
    /// groups it with ``folder``, so the same `.app` reports everything inside
    /// it the way Get Info does. Both groupings are deliberate, and as switch
    /// arms they are visible rather than buried in a boolean expression.
    enum Shape: Sendable, Hashable {
        /// A directory, presented as a directory.
        case folder
        /// A directory the file system presents as one item — an `.app`, an
        /// `.rtfd`.
        case package
        /// Not a directory.
        case file
        /// The file system described the path without saying which of the above
        /// it is.
        ///
        /// Distinct from ``file`` on purpose, and distinct from the initialiser
        /// returning nil. "I could not tell" is not "it is a file", and
        /// collapsing the two is what let a re-copy of an ejected folder
        /// overwrite a row that already said Folder. Practically unreachable —
        /// a lookup that cannot answer for `.isDirectoryKey` throws rather than
        /// returning a blank — but the readers disagree about what to do with
        /// it, so it is carried rather than guessed.
        case unknown
    }

    /// The file this describes. Carried because measuring a directory means
    /// walking it — see ``DirectorySize`` — and the walk needs somewhere to
    /// start.
    let url: URL
    /// What the path turned out to be.
    let shape: Shape
    /// The file's own size, and nil for anything the file system would not
    /// measure.
    ///
    /// Meaningless for a directory, and *not* reliably nil for one: Darwin
    /// answers `.fileSizeKey` with nil for a directory, swift-corelibs-foundation
    /// answers with the directory entry's own size — 40 bytes for an empty one,
    /// verified against Swift 6.3 on `aarch64-unknown-linux-gnu` rather than
    /// assumed. Nothing reads it on that path, because ``ContentSize`` sends
    /// ``Shape/folder`` and ``Shape/package`` to ``DirectorySize`` instead, and
    /// nothing should start: the number means different things on the two
    /// platforms.
    let fileSize: Int?
    /// Whether the file *declares* itself a picture.
    ///
    /// The declared type, never the bytes: it comes off the same
    /// `resourceValues` call the shape does, so naming pictures costs no extra
    /// trip to a volume that may be slow or gone. ``FileURLKind`` turns it into
    /// ``ClipKind/imageFile`` so the row reads "Image" rather than "File";
    /// ``ContentSize`` ignores it, which is why this is a property beside
    /// ``shape`` rather than another ``Shape`` case both readers would have to
    /// answer for.
    ///
    /// False, not nil, for "the file system did not say so" — a file with no
    /// extension declares the generic `public.data` and is indistinguishable
    /// here from a spreadsheet. ``ThumbnailRenderer`` upgrades that case later,
    /// once a picture has actually been decoded out of the file, which is the
    /// only evidence stronger than the declared type.
    ///
    /// Always false on Linux, where there is no `UniformTypeIdentifiers` to ask
    /// and `URLResourceValues` therefore has no `contentType`. A Linux row reads
    /// "File", which is what every row read before pictures were told apart.
    let isImage: Bool

    /// A description assembled by the caller rather than read off a disk.
    ///
    /// Production has exactly one source for these — ``init(at:)`` — and should
    /// keep it that way: a `CopiedFile` naming a shape the file system never
    /// reported is a lie the readers cannot detect. It exists because
    /// ``FileURLKind/kind(of:)`` and ``ContentSize/byteCount(of:)`` are total
    /// functions over ``Shape``, and the arm that matters most —
    /// ``Shape/unknown``, where the two deliberately disagree — is the one no
    /// real path can be made to produce.
    init(url: URL, shape: Shape, fileSize: Int?, isImage: Bool = false) {
        self.url = url
        self.shape = shape
        self.fileSize = fileSize
        self.isImage = isImage
    }

    /// Asks the file system about `url`, once.
    ///
    /// Nil when it would not answer at all — deleted since the copy, on an
    /// unmounted volume, behind a sandbox. That is a different fact from any
    /// ``Shape``, and it is the one both readers turn into "nothing to say
    /// about this row".
    init?(at url: URL) {
        // `.contentTypeKey` and the `contentType` that reads it are
        // UniformTypeIdentifiers, which Darwin has and swift-corelibs-foundation
        // does not. Asking for a key the platform does not know would fail the
        // whole lookup, so the key set is built alongside the answer rather than
        // the answer being fished out of a fixed one.
        #if canImport(UniformTypeIdentifiers)
            let keys: Set<URLResourceKey> = [
                .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey,
            ]
        #else
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        #endif

        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        self.url = url
        shape =
            switch values.isDirectory {
            case true: values.isPackage == true ? .package : .folder
            case false: .file
            default: .unknown
            }
        fileSize = values.fileSize
        #if canImport(UniformTypeIdentifiers)
            isImage = values.contentType?.conforms(to: .image) == true
        #else
            isImage = false
        #endif
    }
}
