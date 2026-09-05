import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// macOS's policy for programmatic reads of the general pasteboard.
///
/// A value type mirroring `NSPasteboard.AccessBehavior` so the rest of Skrepka —
/// and its tests — need no live pasteboard. AppKit is imported here for the
/// bridging initialiser only; `SkrepkaCore` still holds no view types.
///
/// The enum itself is portable and the diagnostics types built on it port with
/// it. Only ``init(_:)`` is macOS-only, because only macOS has a policy to
/// mirror: X11 and Wayland gate clipboard reads on nothing, so a Linux
/// ``ClipboardSource`` reports ``alwaysAllow`` unconditionally.
public enum PasteboardAccess: Sendable, Hashable, CaseIterable {
    /// Never asked. Per `NSPasteboard.h` an app in this state is not listed in
    /// System Settings at all, so this cannot be read as "working" — it means
    /// the question has not been put to the user yet.
    case notYetAsked
    /// The system prompts on programmatic access.
    case ask
    /// Reads are allowed without prompting. What a clipboard manager needs.
    case alwaysAllow
    /// Reads are refused silently. Skrepka sees an empty pasteboard forever.
    case alwaysDeny

    #if canImport(AppKit)
        public init(_ behavior: NSPasteboard.AccessBehavior) {
            self =
                switch behavior {
                case .default: .notYetAsked
                case .ask: .ask
                case .alwaysAllow: .alwaysAllow
                case .alwaysDeny: .alwaysDeny
                // NSPasteboardAccessBehavior is a plain NS_ENUM, so a future
                // release may add a case this build has never heard of. Treating
                // an unknown policy as "not yet asked" keeps the diagnostics
                // honest — it claims nothing it cannot prove.
                @unknown default: .notYetAsked
                }
        }
    #endif

    /// Whether this policy alone proves capture is blocked.
    ///
    /// Only `.alwaysDeny` does. `.notYetAsked` and `.ask` are undecided, and
    /// the answer for those comes from ``CaptureHealth`` — what the reads
    /// actually did — not from the policy.
    public var isBlocking: Bool { self == .alwaysDeny }

    public var summary: String {
        switch self {
        case .notYetAsked: "Not yet requested"
        case .ask: "Ask each time"
        case .alwaysAllow: "Allowed"
        case .alwaysDeny: "Denied"
        }
    }
}
