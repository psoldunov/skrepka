import Foundation

/// Why a peer's TXT record could not be read as a Skrepka advertisement.
///
/// Every case is a *named* failure that travels with the peer rather than
/// removing it from the list. "Why can I not see my other machine" is the bug
/// report this exists to prevent, and a peer that was silently skipped leaves
/// nothing to answer it with.
public enum AdvertisementError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A key this build needs was not in the record.
    ///
    /// Only `txtvers`, `id` and `proto` are required. Without an identifier
    /// there is nothing to pin, and without a protocol version there is no way
    /// to decide what to say — those are the keys whose absence leaves nothing
    /// to do with the peer. `name` and `plat` are optional and degrade instead.
    case missingKey(String)

    /// The record's `txtvers` is not one this build reads.
    ///
    /// RFC 6763 §6.7 makes this the version of the record's *grammar*, so a
    /// value this build does not know means the keys below it cannot be trusted
    /// to mean what they usually mean. Unlike an unknown `proto`, which is a
    /// peer worth talking to, an unknown `txtvers` is a record that cannot be
    /// read at all.
    case unsupportedRecordVersion(String)

    /// A key was present and its value was not what the key requires.
    case malformedValue(key: String, reason: String)

    /// The record's bytes were not a well-formed TXT record.
    ///
    /// Carries a reason rather than the underlying ``TXTRecordError`` for the
    /// same reason `FrameError.malformedBody(reason:)` does: nothing above the
    /// codec should name the codec's error type, or replacing the codec stops
    /// being cheap.
    case malformedRecord(reason: String)

    public var description: String {
        switch self {
        case .missingKey(let key):
            "advertisement has no \"\(key)\" key"
        case .unsupportedRecordVersion(let version):
            "advertisement is txtvers \(version), and this build reads \(ServiceDescriptor.recordVersion)"
        case .malformedValue(let key, let reason):
            "advertisement key \"\(key)\" is malformed: \(reason)"
        case .malformedRecord(let reason):
            "advertisement is not a well-formed TXT record: \(reason)"
        }
    }
}
