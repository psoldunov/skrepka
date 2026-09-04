import Foundation

/// Why a pasteboard change was or was not turned into a history entry.
///
/// Modelled explicitly so the reasons are testable without a live pasteboard,
/// and so the UI can explain "nothing was captured" rather than looking broken.
public enum CaptureDecision: Sendable, Equatable {
    case captured(ClipItem)
    /// Carried a transient or auto-generated privacy marker.
    case rejectedPrivacyMarker
    /// The source app is on the user's exclusion list.
    case rejectedExcludedApp(bundleID: String)
    /// Nothing readable in any type Clippy understands.
    case rejectedEmpty
    /// Larger than the configured per-item ceiling.
    case rejectedTooLarge(byteCount: Int)

    public var item: ClipItem? {
        guard case .captured(let item) = self else { return nil }
        return item
    }
}
