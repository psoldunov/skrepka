import Foundation

/// The shape of a `contentHash`: SHA-256 as 64 lowercase hex characters, which
/// is what `ClipItem.contentHash` produces on both platforms and the only
/// thing any build of this protocol has ever sent.
///
/// Checked where a peer's hash enters — every item and tombstone a frame
/// decodes — because a hash is used as more than a key: it names a directory
/// of received files, and a peer is authenticated rather than trusted. A frame
/// carrying anything else is refused whole, like any other malformed frame.
public enum ContentHash {
    public static let length = 64

    public static func isValid(_ string: String) -> Bool {
        string.utf8.count == length
            && string.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
