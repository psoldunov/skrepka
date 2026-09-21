import Foundation

/// The contents of copied files, carried as one representation so a file copy
/// reaches a peer as files rather than as a path that exists only here.
///
/// A file copy used to cross as `text/uri-list` alone — the sender's own path,
/// see ``RepresentationKeyMap`` — and a receiver writing that onto its clipboard
/// pasted a reference to nothing. The bundle is read at copy time, so a file
/// moved or deleted afterwards still pastes as it was copied.
///
/// On the wire it is one CBOR array of `{name, size, bytes}` maps, one per
/// copied file, under ``canonicalKey``. Folders are not bundled; a copy holding
/// nothing but folders, or more than ``SyncLimits/maximumPayloadBytes`` in
/// total, has no bundle at all and a receiver pastes its names instead.
///
/// **Names are the sender's, verbatim.** Nothing here makes one safe to use as
/// a path — a paired peer is authenticated, not trusted — so whoever writes a
/// bundle to disk sanitises every name first. See `SkrepkaCore.FileMaterializer`.
public struct FileBundle: Sendable, Hashable {
    /// The media type the bundle travels under.
    public static let canonicalKey = "application/vnd.skrepka.files+cbor"

    /// The private macOS type a store keeps the bundle under. Not a type any
    /// pasteboard carries: it exists so a store keyed by macOS type — both of
    /// them are, see ``RepresentationKeyMap/utiKeyed(_:)`` — does not drop it.
    public static let storageType = "dev.soldunov.skrepka.files"

    /// Most files one bundle may carry.
    ///
    /// The byte ceiling alone does not bound the *count*: 32 MB holds some
    /// 150,000 empty files, and a receiver materialising them spends an inode
    /// and a directory entry on each — a paired peer could exhaust a small
    /// volume's inodes with one push. A thousand is far past any selection a
    /// person copies to paste somewhere else, and a copy of more crosses as
    /// its names, like a folder does.
    public static let maximumFileCount = 1000

    /// The wire key for a bundle held by this device.
    public static let key = RepresentationKey(canonical: canonicalKey, origin: storageType)

    /// One copied file.
    public struct File: Sendable, Hashable {
        /// The file's own name on the machine that copied it. Unsanitised.
        public let name: String
        public let bytes: Data

        public init(name: String, bytes: Data) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// In the order the files were copied.
    public let files: [File]

    public init(files: [File]) {
        self.files = files
    }

    /// Total bytes of file content, not counting the encoding around it.
    public var contentByteCount: Int {
        files.reduce(0) { $0 + $1.bytes.count }
    }

    /// The first file, when it is the only one and its bytes are a picture a
    /// clipboard can carry as one — see ``ImageSignature``.
    ///
    /// What lets a synced screenshot read as an image rather than as a file:
    /// a receiver shows and pastes these bytes as well as the file.
    public var singleImage: (type: ImageSignature, bytes: Data)? {
        guard files.count == 1, let file = files.first,
            let type = ImageSignature(sniffing: file.bytes)
        else { return nil }
        return (type, file.bytes)
    }
}
