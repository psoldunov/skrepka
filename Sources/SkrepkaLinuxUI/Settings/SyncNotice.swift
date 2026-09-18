import Foundation

/// A line at the top of the window saying how something the user asked for
/// went.
///
/// Transient where it is good news, and kept where it is not: a success that
/// lingers is clutter, and a problem that vanishes before it is read is a
/// problem the user never heard about.
public struct SyncNotice: Sendable, Hashable {
    public enum Tone: Sendable, Hashable {
        case success
        case info
        case problem
    }

    public let tone: Tone
    public let message: String
    public let detail: String?
    /// When it clears itself, or nil to stay until dismissed.
    public let clearsAt: Date?

    /// How long good news stays up.
    static let successLifetime: TimeInterval = 6

    static func success(_ message: String, now: Date) -> SyncNotice {
        SyncNotice(tone: .success, message: message, detail: nil, clearsAt: now + successLifetime)
    }

    static func info(_ message: String) -> SyncNotice {
        SyncNotice(tone: .info, message: message, detail: nil, clearsAt: nil)
    }

    static func problem(_ failure: SyncFailure) -> SyncNotice {
        SyncNotice(tone: .problem, message: failure.message, detail: failure.remedy, clearsAt: nil)
    }
}
