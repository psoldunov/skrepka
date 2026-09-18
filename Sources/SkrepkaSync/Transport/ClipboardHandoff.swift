/// The content a peer last put on this device's clipboard, for exactly as long
/// as nothing else has been copied since.
///
/// ``RecentHashes`` suppresses an echo for thirty seconds, and that window was
/// once the whole guard. Anything slower got through: a received push that
/// Universal Clipboard relays on to another Mac and back, a Linux compositor
/// echoing a write after the watcher had resumed. Each came back here as a
/// fresh copy, went out to every peer again, and overwrote a newer clipboard
/// with older content on the way.
///
/// This one does not age. It remembers a single hash — the clipboard holds one
/// thing — and forgets it the moment anything else is copied, recorded or not,
/// which is the first point at which this device can know the user has moved
/// on. Until then a capture of the same content is the handed-over content
/// coming back, not a copy: the peer that sent it already holds it.
///
/// The cost is deliberate and small. Re-copying the item a peer just handed
/// over, with nothing copied in between, is not pushed. The sender still holds
/// it unless its own clipboard changed without a capture — pasting an older
/// entry from the Mac picker is the one way that happens.
///
/// A value type with no clock, for the reason ``RecentHashes`` is one: the rule
/// is the part worth testing. Internal because it is one half of a guard:
/// ``LivePushGate`` owns it beside the hash window, so no caller can consult
/// one and forget the other.
struct ClipboardHandoff: Sendable, Hashable {
    private var handedOver: String?

    /// A peer's push is about to be put on this device's clipboard.
    ///
    /// Called before the write rather than after, so a capture of the write
    /// cannot arrive first. A newer push replaces an older one.
    mutating func received(_ hash: String) {
        handedOver = hash
    }

    /// Something was copied on this device.
    ///
    /// The handed-over content itself leaves the hand-over standing — it is the
    /// write coming back. Anything else ends it for good, so the same content
    /// copied again afterwards is a copy like any other. `nil` is a copy whose
    /// hash is unknown because the capture rules refused it before hashing —
    /// a password, an excluded app — and it ends the hand-over too: whatever
    /// it was, the clipboard no longer holds what the peer sent.
    mutating func captured(_ hash: String?) {
        if hash == nil || hash != handedOver { handedOver = nil }
    }

    /// Whether `hash` is still the content a peer handed over.
    func isHandedOver(_ hash: String) -> Bool {
        handedOver == hash
    }
}
