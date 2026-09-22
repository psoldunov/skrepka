import Foundation

/// How large a copy of files may be and still have its contents synced — the
/// "Sync files up to" setting on both platforms.
///
/// Measured against the encoded ``FileBundle``, the one representation that
/// carries the files, so the number a user picks is the number that crosses the
/// wire, framing included.
///
/// **Zero means file contents never sync.** A copy of files still reaches a
/// peer, as its names, exactly as a folder or a copy over the limit does. There
/// is no "no limit": a bundle is one representation, so the largest choice is
/// the protocol's payload ceiling, and a copy above that has never synced.
///
/// Each device applies its own limit three times, so that a lower limit on
/// either end is the one that wins:
///
/// - when a copy is made, a bundle over the limit is not read at all — see
///   `FileBundleReader.attachingBundle(to:limit:)`;
/// - when history is offered or pushed to a peer, a bundle captured under a
///   higher limit is withheld — see ``CapabilityFilter/limitingFiles(to:)``;
/// - when a peer offers one, a bundle over the limit is not fetched — see
///   ``SyncExchange``.
public enum FileSyncLimit {
    /// One mebibyte, the unit the choices are written in.
    ///
    /// Binary, because the ceiling it has to land on exactly is
    /// `32 * 1024 * 1024`; a pane labels each choice in "MB", as everything in
    /// this project that has described that ceiling always has.
    public static let megabyte = 1024 * 1024

    /// The largest limit there is: ``SyncLimits/maximumPayloadBytes``.
    public static let ceiling = SyncLimits.maximumPayloadBytes

    /// What a device syncs before anyone touches the setting — the ceiling,
    /// which is what every build did before the setting existed.
    public static let defaultBytes = ceiling

    /// What a settings pane offers, smallest first. 0 is "don't sync file
    /// contents".
    public static let choices = [0, 1, 5, 10, 20, 32].map { $0 * megabyte }

    /// `bytes` brought into range: below zero is zero, past the ceiling is the
    /// ceiling. A value read from a file or a defaults domain goes through this
    /// before anything trusts it.
    public static func clamped(_ bytes: Int) -> Int {
        min(max(bytes, 0), ceiling)
    }

    /// Whether a bundle of `byteCount` bytes may sync under `limit`.
    ///
    /// A limit of zero admits nothing — not even a bundle of empty files, which
    /// would otherwise be the one thing "don't sync file contents" still sent.
    ///
    /// A negative count admits nothing either: only a malformed or hostile
    /// offer carries one, and read as "small" it would slip past every limit.
    public static func admits(_ byteCount: Int, under limit: Int) -> Bool {
        limit > 0 && byteCount >= 0 && byteCount <= limit
    }

    /// Whether the representation `descriptor` names may sync under `limit`.
    /// Only a bundle is ever measured; every other form of a copy always may.
    public static func admits(_ descriptor: RepresentationDescriptor, under limit: Int) -> Bool {
        !isBundle(descriptor.key) || admits(descriptor.byteCount, under: limit)
    }

    /// `payloads` without a bundle over `limit`, measured by the bytes that
    /// actually came rather than by any size a peer claimed for them.
    public static func admitted(
        _ payloads: [RepresentationKey: Data],
        under limit: Int
    ) -> [RepresentationKey: Data] {
        payloads.filter { key, bytes in !isBundle(key) || admits(bytes.count, under: limit) }
    }

    /// The most a fetch of `key` may read: `budget`, and for a bundle no more
    /// than `limit` either — a peer that understated a bundle's size must not
    /// be able to deliver more than this device agreed to take.
    public static func fetchCap(for key: RepresentationKey, budget: Int, limit: Int) -> Int {
        isBundle(key) ? min(budget, limit) : budget
    }

    static func isBundle(_ key: RepresentationKey) -> Bool {
        key.canonical == FileBundle.canonicalKey
    }
}
