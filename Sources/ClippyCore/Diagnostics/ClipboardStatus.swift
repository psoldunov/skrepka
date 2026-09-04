import Foundation

/// Whether clipboard capture is known to work, known to be blocked, or simply
/// has not been exercised yet.
public enum ClipboardStatus: Sendable, Hashable, CaseIterable {
    /// Proven — a read demonstrably succeeded, or the user set Always Allow.
    case working
    /// Denied outright, or a run of reads came back empty-handed.
    case blocked
    /// Never asked, or asks each time, and nothing has been read yet.
    case unknown

    /// Weighs what macOS *would* do against what the reads actually did.
    ///
    /// Policy alone cannot answer this: `NSPasteboard.h` says an app that has
    /// never triggered the access alert reports `.default`, which is the same
    /// value a working app and a broken one both show — and an "Allow Once"
    /// leaves it at `.ask` forever. So evidence outranks policy, and only
    /// `.alwaysDeny` is conclusive on its own.
    public init(access: PasteboardAccess, isCaptureBlocked: Bool, hasReadSuccessfully: Bool) {
        if isCaptureBlocked || access.isBlocking {
            self = .blocked
        } else if hasReadSuccessfully || access == .alwaysAllow {
            self = .working
        } else {
            self = .unknown
        }
    }

    /// The live reading, from the policy and the record of what capture has
    /// been doing.
    @MainActor
    public init(access: PasteboardAccess, health: CaptureHealth) {
        self.init(
            access: access,
            isCaptureBlocked: health.isBlocked,
            hasReadSuccessfully: health.hasReadSuccessfully
        )
    }
}
