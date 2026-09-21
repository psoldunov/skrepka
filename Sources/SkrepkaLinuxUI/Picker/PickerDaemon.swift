import SkrepkaIPC

/// What the picker needs from the daemon, and nothing more.
///
/// A seam over ``DaemonProxy`` so the window can be driven by a fake in a test
/// or the palette demo, the same way `SyncDaemon` narrows the daemon for the
/// Settings window. Every member is one the daemon exports at interface
/// version 3 — see `SkrepkaInterface`.
public protocol PickerDaemon: Sendable {
    /// History, newest first with pinned entries hoisted. `limit` of 0 is all.
    func history(limit: UInt32) async throws -> HistoryDocument
    /// The entries matching `query`, best first. A blank query answers history.
    func search(_ query: String, limit: UInt32) async throws -> HistoryDocument
    /// The current settings, including whether a copied entry should paste.
    func settings() async throws -> SettingsDocument
    /// Puts one entry on the clipboard in the chosen style.
    func copy(_ selector: ClipSelector, style: CopyStyle) async throws -> ActionDocument
    /// Pins or unpins one entry.
    func setPinned(_ selector: ClipSelector, _ pinned: Bool) async throws -> ActionDocument
    /// Deletes one entry.
    func delete(_ selector: ClipSelector) async throws -> ActionDocument
    /// The picture one entry holds. `maxBytes` of 0 asks the daemon's default.
    func preview(_ selector: ClipSelector, maxBytes: UInt32) async throws -> PreviewDocument
    /// One element per `HistoryChanged`, until the caller stops reading.
    func historyChanges() async throws -> AsyncStream<Void>
    /// Every entry whose bytes are arriving from a peer now. Since interface
    /// version 5.
    func transfers() async throws -> TransfersDocument
    /// One snapshot per `TransfersChanged`, until the caller stops reading.
    func transferChanges() async throws -> AsyncStream<TransfersDocument>
}

extension PickerDaemon {
    /// Default-on settings for picker demos and fakes that have no settings store.
    public func settings() async throws -> SettingsDocument {
        SettingsDocument(
            retention: .init(maximumItems: 500, maximumAgeDays: 30),
            sync: .init(isEnabled: true, isLockedOff: false),
            history: .init(entries: 0, pinned: 0, images: 0),
            protectedMarkers: []
        )
    }

    /// Nothing arriving — what a fake that predates transfers answers.
    public func transfers() async throws -> TransfersDocument {
        TransfersDocument(transfers: [])
    }

    /// A stream that never yields and ends at once, for the same fakes.
    public func transferChanges() async throws -> AsyncStream<TransfersDocument> {
        AsyncStream { $0.finish() }
    }
}

/// The real daemon. Every member already exists on ``DaemonProxy`` with a
/// matching signature, so the conformance adds no code — it only states that a
/// proxy is what the picker talks to in production.
extension DaemonProxy: PickerDaemon {}
