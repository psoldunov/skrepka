import Foundation

/// The operating system on the far end of a pairing.
///
/// Carried in the discovery record's `plat=` key and in `hello`, where it is
/// load-bearing rather than decorative: it is what decides the live-push
/// default.
public enum PeerPlatform: String, Sendable, Hashable, Codable, CaseIterable {
    case macos
    case linux
    /// A platform this build has never heard of. Reached by decoding a `plat=`
    /// value a newer peer invented, which is a thing to tolerate rather than a
    /// thing to reject.
    case unknown

    /// Maps a wire value, tolerating one this build does not recognise.
    ///
    /// Forward compatibility is the point: a peer advertising a platform added
    /// after this build shipped is still a peer worth talking to, it just does
    /// not get live push by default.
    public init(wireValue: String) {
        self = PeerPlatform(rawValue: wireValue) ?? .unknown
    }

    /// Whether live clipboard push should default on between these two
    /// platforms.
    ///
    /// Never between two Apple devices — Universal Clipboard already does that,
    /// and two systems owning one pasteboard race non-deterministically. Live
    /// push exists to bridge the gap Apple leaves.
    ///
    /// ``unknown`` defaults live push **off** in either position. An
    /// unrecognised platform is more likely a future Apple device than a future
    /// Linux one, and the failure mode of guessing wrong in that direction is a
    /// feature the user has to switch on rather than a pasteboard collision the
    /// user cannot diagnose.
    ///
    /// Answers from ``LivePushDefault/between(local:remote:)``, which carries
    /// the same rule plus the reason a settings row has to state. Two spellings
    /// of one rule is one rule and one bug.
    public static func livePushDefaultsOn(local: PeerPlatform, remote: PeerPlatform) -> Bool {
        LivePushDefault.between(local: local, remote: remote).isOn
    }
}
