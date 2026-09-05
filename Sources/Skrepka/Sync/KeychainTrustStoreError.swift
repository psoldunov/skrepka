// periphery:ignore:all
//
// The error type of `KeychainTrustStore`, which has no caller until Phase 3 —
// see the directive at the top of that file for why it is written ahead of one.

import Foundation

/// Why the Keychain could not answer for this device's identity.
///
/// Every case is worth surfacing rather than recovering from: the answer to all
/// of them is "this Mac cannot prove who it is", and generating a fresh
/// identity to get past one would silently un-pair the device from every peer.
nonisolated enum KeychainTrustStoreError: Error, CustomStringConvertible {
    /// `SecItemAdd` reported an item already there, which is another task
    /// having won the race to create the identity.
    case alreadyExists

    /// The item was there a moment ago and is not now. A user emptying their
    /// keychain mid-launch reaches this; nothing else should.
    case identityVanished

    /// The item exists and its data is not what this app wrote.
    case unreadableItem

    case keychain(status: OSStatus)

    var description: String {
        switch self {
        case .alreadyExists:
            "a device identity already exists in the keychain"
        case .identityVanished:
            "the device identity disappeared from the keychain between two reads"
        case .unreadableItem:
            "the keychain item holding the device identity is not readable as one"
        case .keychain(let status):
            "keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "no message")"
        }
    }
}
