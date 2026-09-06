import Foundation

/// What the user has said about live push for one peer.
///
/// Three cases rather than an optional boolean, and not only because SwiftLint's
/// `discouraged_optional_boolean` says so: "the user has not chosen" is a state
/// this store has to persist and a settings row has to render differently from
/// "the user chose off", and an `Optional<Bool>` spells all three with two words
/// that read as one. Named cases also give the storage layer a raw value to
/// write, the way ``PeerPlatform`` already does.
public enum LivePushChoice: String, Sendable, Hashable, CaseIterable, Codable {
    /// Nothing recorded. ``LivePushDefault`` decides.
    case followsPlatformDefault
    case on
    case off

    /// Reads a stored value, tolerating one this build has never heard of.
    ///
    /// A row written by a newer build falls back to the platform default rather
    /// than failing the peer: an unreadable preference is a reason to use the
    /// default, never a reason to lose the pairing.
    public init(storedValue: String?) {
        self = storedValue.flatMap(LivePushChoice.init(rawValue:)) ?? .followsPlatformDefault
    }

    /// What a store writes, or nil for "nothing recorded".
    public var storedValue: String? {
        self == .followsPlatformDefault ? nil : rawValue
    }
}
