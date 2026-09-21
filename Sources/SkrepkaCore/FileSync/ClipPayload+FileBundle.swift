import Foundation
import SkrepkaSync

// MARK: - The file bundle is storage, not clipboard content

extension ClipPayload {
    /// The payload as a clipboard should carry it: without the file bundle.
    ///
    /// The bundle is kept beside a file copy so a peer can be sent the files —
    /// see ``FileBundleReader`` — and is up to ``FileBundleReader/limit`` of
    /// bytes under a private type no application reads. Writing it to a
    /// pasteboard would hand every app that inspects the clipboard 32 MB of
    /// nothing it understands.
    public var forClipboard: ClipPayload {
        guard representations[FileBundle.storageType] != nil else { return self }
        return ClipPayload(representations: representations.filter { $0.key != FileBundle.storageType })
    }
}
