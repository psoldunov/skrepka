// The Linux store's conformance to `SkrepkaSync.PairedDeviceStoring`, in a file
// of its own for the reason `+Storing.swift` is: the requirements are worth
// seeing as a checklist rather than buried at the top of the extension that
// implements them. Fenced to Linux with the rest of the SQLite engine (D-3).
#if os(Linux)

    import Foundation
    import SkrepkaSync

    /// `SQLiteHistoryStore` as the trust half of a sync stack sees it.
    ///
    /// Empty because every requirement is already public API of the store, in
    /// `SQLiteHistoryStore+Pairing.swift`: an actor-isolated synchronous method
    /// witnesses an `async` requirement, so the hop happens at the call site and
    /// nothing here needs a forwarding shim. The macOS counterpart is
    /// `Sources/Skrepka/Sync/HistoryStore+PairedDeviceStoring.swift`, which is
    /// the same one-liner for the same reason.
    ///
    /// The eight requirements, and where each lives:
    ///
    /// - ``SQLiteHistoryStore/pairedPeers()`` and
    ///   ``SQLiteHistoryStore/pairedPeer(_:)`` — reading the peer table.
    /// - ``SQLiteHistoryStore/savePairedPeer(_:)`` — insert or replace.
    /// - ``SQLiteHistoryStore/forgetPairedPeer(_:)`` — the peer *and* its
    ///   high-water mark, so a re-paired device is not refused for a downgrade
    ///   it never made.
    /// - ``SQLiteHistoryStore/highestProtocolVersion(for:)`` and
    ///   ``SQLiteHistoryStore/recordProtocolVersion(_:for:)`` — the
    ///   anti-downgrade mark, which never lowers.
    /// - ``SQLiteHistoryStore/livePushChoice(for:)`` and
    ///   ``SQLiteHistoryStore/setLivePushChoice(_:for:)`` — the user's override
    ///   of design §3's platform default, which goes with the peer at
    ///   `forgetPairedPeer`.
    ///
    /// Declared here rather than at the top of `+Pairing.swift` so that the
    /// day a requirement is added to the protocol, the compiler's complaint
    /// lands on a file whose whole purpose is that list.
    extension SQLiteHistoryStore: PairedDeviceStoring {}

#endif
