import Foundation

/// Whether live clipboard push is on for a pair of platforms when nobody has
/// said otherwise, and *why*.
///
/// The reason is carried rather than derived from the boolean because design §11
/// requires the peer row to state it: "a macOS peer should show it off *with the
/// reason stated in the row* — 'Universal Clipboard already does this' — rather
/// than as an unexplained disabled switch". A bare `false` cannot be rendered
/// into that sentence, and a UI that reconstructs the reason from the two
/// platforms is the rule written twice.
///
/// The English lives in the app target. This target builds on Linux and has no
/// business owning user-facing copy; what it owns is which of the three cases
/// applies.
public enum LivePushDefault: Sendable, Hashable, CaseIterable {
    /// A cross-platform pair. Live push is the whole point of it — see
    /// design §3.
    case on

    /// Two Apple devices. Universal Clipboard already carries the live
    /// clipboard between them, and two systems owning one pasteboard race
    /// non-deterministically.
    case offBetweenAppleDevices

    /// One of the two platforms is a value this build has never heard of.
    ///
    /// Off, in either position. An unrecognised platform is more likely a
    /// future Apple device than a future Linux one, and the failure mode of
    /// guessing wrong in that direction is a feature the user has to switch on
    /// rather than a pasteboard collision the user cannot diagnose.
    case offForUnrecognisedPlatform

    public var isOn: Bool { self == .on }

    /// The default for one pair.
    ///
    /// The single source of truth for design §3's rule.
    /// ``PeerPlatform/livePushDefaultsOn(local:remote:)`` answers from this, so
    /// the boolean and the reason cannot drift apart.
    public static func between(local: PeerPlatform, remote: PeerPlatform) -> LivePushDefault {
        guard local != .unknown, remote != .unknown else { return .offForUnrecognisedPlatform }
        return local == .macos && remote == .macos ? .offBetweenAppleDevices : .on
    }
}
