import Foundation

/// Every payload fetch in flight on this device, and a stream of snapshots for
/// whatever draws them — the macOS picker directly, the Linux one through the
/// daemon's `TransfersChanged` signal.
///
/// ``SyncExchange`` is the only writer. It begins a transfer once it knows what
/// an item's fetch will bring, advances it after every chunk, and ends it once
/// the bytes are stored — after, not when the last chunk lands, so a row never
/// drops back to "not synced yet" in the moment between the two.
///
/// Built once by whoever draws the progress and handed to every
/// ``SyncRuntime`` it builds, so a subscriber outlives a sync restart.
public actor TransferMonitor {
    /// A fetch this small is never reported. It arrives in one reply, so a bar
    /// for it would flash full and vanish.
    public static let reportingThreshold = SyncLimits.payloadChunkBytes

    /// The least time between two progress reports. Beginning and ending a
    /// transfer are reported at once, whatever the spacing: those are the two
    /// changes a row cannot afford to miss, and a skipped step in between is
    /// made up by the next.
    public static let defaultProgressInterval: Duration = .milliseconds(100)

    private let progressInterval: Duration
    private var transfers: [String: PayloadTransfer] = [:]
    /// How many fetches of each item are in flight. Two links can fetch the
    /// same item at once, and the first to finish must not take the other's
    /// bar with it.
    private var fetches: [String: Int] = [:]
    private var observers: [UUID: AsyncStream<[PayloadTransfer]>.Continuation] = [:]
    private var lastProgressReport: ContinuousClock.Instant?

    public init(progressInterval: Duration = TransferMonitor.defaultProgressInterval) {
        self.progressInterval = progressInterval
    }

    /// Every transfer in flight, in content-hash order so two snapshots of the
    /// same state compare equal.
    public var current: [PayloadTransfer] {
        transfers.values.sorted { $0.contentHash < $1.contentHash }
    }

    /// A fetch of `totalBytes` for one item has started. A second fetch of the
    /// same item takes over its bar until one of them ends.
    public func begin(_ contentHash: String, totalBytes: Int) {
        guard totalBytes > Self.reportingThreshold else { return }
        fetches[contentHash, default: 0] += 1
        transfers[contentHash] = PayloadTransfer(
            contentHash: contentHash, receivedBytes: 0, totalBytes: totalBytes)
        publish(at: .now)
    }

    /// `receivedBytes` of the item's bytes have arrived. Ignored for an item
    /// that was never begun — one under the threshold — or already ended.
    public func advance(_ contentHash: String, to receivedBytes: Int) {
        guard let transfer = transfers[contentHash] else { return }
        transfers[contentHash] = PayloadTransfer(
            contentHash: contentHash, receivedBytes: receivedBytes, totalBytes: transfer.totalBytes)
        let now = ContinuousClock.now
        guard Self.isDue(now, lastReport: lastProgressReport, interval: progressInterval) else { return }
        publish(at: now)
    }

    /// Whether progress may be reported at `now`: nothing has been yet, or the
    /// last report is at least `interval` old.
    static func isDue(
        _ now: ContinuousClock.Instant,
        lastReport: ContinuousClock.Instant?,
        interval: Duration
    ) -> Bool {
        guard let lastReport else { return true }
        return now - lastReport >= interval
    }

    /// The item's fetch is over — stored, refused, or failed. Which of the
    /// three is the history's business; a progress bar only needs to go.
    public func end(_ contentHash: String) {
        guard let count = fetches[contentHash] else { return }
        guard count <= 1 else {
            fetches[contentHash] = count - 1
            return
        }
        fetches[contentHash] = nil
        transfers[contentHash] = nil
        publish(at: .now)
    }

    /// Snapshots from now on, starting with the one that holds now.
    ///
    /// Newest-only buffering: a subscriber that falls behind wants the latest
    /// state, not every step it missed. Each caller gets its own stream, for the
    /// reason `Daemon.historyChanges()` spells out — one shared stream would
    /// hand each snapshot to only one of its readers.
    public func updates() -> AsyncStream<[PayloadTransfer]> {
        let (stream, continuation) = AsyncStream<[PayloadTransfer]>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        continuation.yield(current)
        return stream
    }

    private func publish(at instant: ContinuousClock.Instant) {
        lastProgressReport = instant
        let snapshot = current
        for observer in observers.values { observer.yield(snapshot) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
