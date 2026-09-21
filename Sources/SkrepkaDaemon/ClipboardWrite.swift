import Foundation
import SkrepkaCore
import SkrepkaLinuxPlatform
import SkrepkaSync

/// What one history row puts on this machine's clipboard: its bytes, keyed by
/// the store's pasteboard types, and the local files it names.
///
/// The files are apart from the bytes because a Linux clipboard offers a file
/// list under two targets, and the payload's own `public.file-url` holds one
/// URL — see `LinuxRepresentationMap.decoded(_:forTarget:)`.
///
/// Built by ``Daemon/clipboardWrite(for:)``, which is where a file row from
/// another device stops being its sender's paths — see
/// `SkrepkaCore.ForeignFileGuard`.
struct ClipboardWrite: Sendable, Hashable {
    let representations: [String: Data]
    let fileURLs: [URL]
    /// Whether this is something other than the row as stored: a foreign
    /// file row's files written here, or their names. Captured back, it would
    /// be a second row rather than the same one hoisted.
    let replacesRow: Bool

    init(representations: [String: Data], fileURLs: [URL] = []) {
        self.representations = representations
        self.fileURLs = fileURLs
        replacesRow = false
    }

    init(_ clipboard: ForeignFileGuard.Clipboard) {
        representations = clipboard.payload.representations
        fileURLs = clipboard.fileURLs
        replacesRow = true
    }

    /// Every target this write offers: the bytes the map can name, and the
    /// file list in both Linux spellings in place of the payload's single URL.
    var targets: [String: Data] {
        Daemon.writableTargets(from: representations)
            .merging(LinuxRepresentationMap.fileListTargets(fileURLs)) { _, files in files }
    }

    /// The text target alone, for a paste that must not carry markup, images
    /// or files.
    var plainTargets: [String: Data] {
        Daemon.plainWritableTargets(from: representations)
    }
}
