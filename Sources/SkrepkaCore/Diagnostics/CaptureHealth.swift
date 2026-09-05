import Foundation

/// What the capture loop has actually been doing.
///
/// The policy in ``PasteboardAccess`` says what macOS *would* do; this says
/// what happened. Both are needed: an app that has never triggered the access
/// alert reports `.notYetAsked` whether it is working or not, so only the reads
/// themselves can tell the difference.
@MainActor
@Observable
public final class CaptureHealth {
    /// How many unreadable reads in a row before capture is called blocked.
    ///
    /// Not one. A poll can land between `clearContents()` and the write that
    /// follows it, and that gap yields a single unreadable read on a perfectly
    /// healthy machine. A denied pasteboard yields nothing but these.
    static let blockedThreshold = 3

    public private(set) var lastCapturedAt: Date?
    public private(set) var lastDecision: CaptureDecision?
    public private(set) var consecutiveUnreadable = 0
    /// Set when a deliberate write-then-read round trip came back intact.
    ///
    /// Proof of the same weight as a capture, and the only proof available
    /// when the user answers the system alert with "Allow Once": that leaves
    /// `accessBehavior` reporting `.ask` forever, and a capture may still be a
    /// poll away.
    public private(set) var probeSucceeded = false

    public init() {}

    /// True once enough reads in a row have come back empty-handed to rule out
    /// a transient race.
    public var isBlocked: Bool { consecutiveUnreadable >= Self.blockedThreshold }

    /// Whether anything has demonstrated that a read actually works.
    ///
    /// Deliberately not "has captured": an entry rejected on its content still
    /// proves the bytes arrived, and so does the welcome window's probe.
    public var hasReadSuccessfully: Bool { probeSucceeded || lastCapturedAt != nil }

    /// Records that the deliberate access probe read back what it wrote.
    public func recordSuccessfulProbe() {
        probeSucceeded = true
        consecutiveUnreadable = 0
    }

    public func record(_ decision: CaptureDecision, at date: Date = Date()) {
        lastDecision = decision
        switch decision {
        case .rejectedUnreadable:
            consecutiveUnreadable += 1
        case .captured:
            consecutiveUnreadable = 0
            lastCapturedAt = date
        case .rejectedPrivacyMarker, .rejectedExcludedApp, .rejectedEmpty, .rejectedTooLarge:
            // Any decision Skrepka could only reach by reading real bytes proves
            // access works, so the run resets.
            consecutiveUnreadable = 0
        }
    }
}
