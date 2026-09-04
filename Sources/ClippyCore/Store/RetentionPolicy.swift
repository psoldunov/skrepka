import Foundation

/// How much history to keep. Pinned entries are exempt from both limits.
public struct RetentionPolicy: Sendable, Hashable, Codable {
    /// Maximum unpinned entries, or nil for no count limit.
    public let maximumItems: Int?
    /// Maximum age of an unpinned entry, or nil for no age limit.
    public let maximumAge: TimeInterval?

    public static let `default` = RetentionPolicy(maximumItems: 500, maximumAge: 60 * 60 * 24 * 30)
    public static let unlimited = RetentionPolicy(maximumItems: nil, maximumAge: nil)

    public init(maximumItems: Int?, maximumAge: TimeInterval?) {
        self.maximumItems = maximumItems
        self.maximumAge = maximumAge
    }

    /// Ids to evict, given entries ordered newest first.
    ///
    /// Pure so eviction is testable without a store.
    public func idsToEvict(from entries: [ClipSummary], now: Date = Date()) -> Set<UUID> {
        let unpinned = entries.filter { !$0.isPinned }
        var doomed: Set<UUID> = []

        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            doomed.formUnion(unpinned.filter { $0.createdAt < cutoff }.map(\.id))
        }
        if let maximumItems, unpinned.count > maximumItems {
            let sorted = unpinned.sorted { $0.createdAt > $1.createdAt }
            doomed.formUnion(sorted.dropFirst(maximumItems).map(\.id))
        }
        return doomed
    }
}
