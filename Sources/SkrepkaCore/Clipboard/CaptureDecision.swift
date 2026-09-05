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
    /// Nothing readable in any type Skrepka understands.
    case rejectedEmpty
    /// The pasteboard declared types Skrepka reads, but handed back no data for
    /// any of them.
    ///
    /// Distinct from ``rejectedEmpty`` on purpose. macOS gates programmatic
    /// reads of the general pasteboard — `NSPasteboard.h` documents
    /// `NSPasteboardAccessBehavior`, whose default is to ask, and whose
    /// `.alwaysDeny` returns nothing at all — so this is what a denied read
    /// looks like from inside the app. Collapsing the two made a permission
    /// problem indistinguishable from an empty clipboard.
    case rejectedUnreadable
    /// Larger than the configured per-item ceiling.
    case rejectedTooLarge(byteCount: Int)

    public var item: ClipItem? {
        guard case .captured(let item) = self else { return nil }
        return item
    }

    /// Why nothing was stored, in a line fit for the log. Nil for a capture,
    /// which needs no explanation.
    ///
    /// Lives on the decision rather than at the call site so a new case cannot
    /// be added without the compiler asking what it should say.
    public var rejectionLogMessage: String? {
        switch self {
        case .captured:
            nil
        case .rejectedPrivacyMarker:
            "Skipped an entry marked transient or concealed."
        case .rejectedExcludedApp(let bundleID):
            "Skipped an entry from excluded app \(bundleID)."
        case .rejectedEmpty:
            "Skipped an empty pasteboard change."
        case .rejectedTooLarge(let byteCount):
            "Skipped an entry of \(byteCount) bytes — over the size limit."
        case .rejectedUnreadable:
            "The pasteboard changed but returned no readable data."
        }
    }

    /// Whether the rejection is worth more than debug-level noise.
    ///
    /// On a machine where the pasteboard is denied, ``rejectedUnreadable`` is
    /// every copy the user makes and the only trace of why history stays
    /// empty — so it must survive a default log collection.
    public var isNoteworthyRejection: Bool {
        switch self {
        case .rejectedUnreadable, .rejectedTooLarge: true
        case .captured, .rejectedPrivacyMarker, .rejectedExcludedApp, .rejectedEmpty: false
        }
    }
}
