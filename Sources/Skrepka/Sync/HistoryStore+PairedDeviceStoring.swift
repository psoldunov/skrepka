import Foundation
import SkrepkaCore
import SkrepkaSync

/// Declares in the app target what `HistoryStore+Pairing.swift` already
/// implements in `SkrepkaCore`.
///
/// The conformance cannot live beside the methods: `SkrepkaSync` is where the
/// protocol is declared and `SkrepkaCore` depends on it, but the edge only
/// points that way — so `SkrepkaCore` may name `PairedDeviceStoring` and this
/// is still the tidiest place to say the store satisfies it, next to the
/// `KeychainTrustStore` that composes with it.
///
/// `nonisolated` on the conformance, against the app target's inferred
/// main-actor one: the connection actors that read a trust store are not on the
/// main actor. The witnesses are `@MainActor` and synchronous, which is exactly
/// what an `async` requirement is for — the caller awaits and the hop happens
/// where it belongs.
extension HistoryStore: nonisolated PairedDeviceStoring {}
